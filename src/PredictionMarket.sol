// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PredictionMarket
/// @author Daniel Sanchez 
/// @notice UUPS-upgradeable binary prediction market for BTC, ETH, and DOT price movements.
/// @dev Implements a daily-epoch binary options system where traders bet on whether an asset's
/// price will go UP or DOWN within a 24-hour UTC-aligned window. The contract uses an
/// owner-fed oracle model (no direct Chainlink integration) and a Polymarket-style off-chain
/// orderbook with on-chain settlement via EIP-712 signed orders.
///
/// Architecture overview:
///   - **Epochs**: Each asset has sequential daily epochs (24h windows). Epochs are bootstrapped
///     once via `bootstrapDailyEpochs()` and then rolled forward via `rollDaily()`.
///   - **Shares**: The treasury mints paired UP/DOWN outcome shares backed 1:1 by native
///     collateral. Shares are traded via signed orders and redeemed after epoch resolution.
///   - **Settlement**: A privileged matcher bot discovers order crosses off-chain and submits
///     them for atomic on-chain execution via `matchOrdersPolymarketStyle()`.
///   - **Resolution**: After an epoch ends, the owner pushes a fresh oracle price and resolves
///     the epoch, determining the winning outcome based on start vs. final price.
///   - **Upgrades**: UUPS proxy pattern with owner-gated upgrade authorization.
///
/// @custom:oz-upgrades-from PredictionMarket
/// @custom:security-contact danisabcheezzz@gmail.com
contract PredictionMarket is
    Initializable,
    OwnableUpgradeable,
    EIP712Upgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    // ──────────────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Fixed duration of every market epoch.
    /// @dev All epochs are exactly 24 hours, aligned to UTC day boundaries.
    uint256 public constant EPOCH_DURATION = 1 days;

    /// @notice Basis points denominator used for order pricing (100% = 10,000 bps).
    /// @dev Order prices are expressed as uint16 in range [1, 9999] bps, representing
    /// the probability/cost of one outcome share as a fraction of the full collateral unit.
    uint256 public constant PRICE_BPS_DENOMINATOR = 10_000;

    /// @notice Default maximum acceptable age for oracle price data.
    /// @dev If `block.timestamp - priceData.updatedAt > maxPriceAge`, the price is
    /// considered stale and operations depending on it will revert.
    uint256 public constant DEFAULT_MAX_PRICE_AGE = 2 days;

    /// @notice EIP-712 typehash for the `Order` struct, used for off-chain signing and on-chain verification.
    /// @dev Must match the exact field ordering and types in the `Order` struct. Any change to the
    /// struct requires updating this constant, invalidating all previously signed orders.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,uint8 asset,uint256 epochId,uint8 outcome,uint8 side,uint16 priceBps,uint128 shares,uint64 expiry,uint64 nonce,bytes32 salt)"
    );

    // ──────────────────────────────────────────────────────────────────────────────
    // Enums
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Supported trading assets with independent epoch timelines and oracle feeds.
    /// @dev Encoded as uint8 in storage and EIP-712 signatures. Adding new assets requires
    /// updating `_validateAsset()` and the `bootstrapDailyEpochs()` loop bound.
    enum Asset {
        BTC,
        ETH,
        DOT
    }

    /// @notice Binary outcome for each epoch's price direction.
    /// @dev DOWN = 0, UP = 1. Used as mapping keys for outcome share balances.
    enum Outcome {
        DOWN,
        UP
    }

    /// @notice Order intent direction in the orderbook.
    /// @dev BUY = 0 (trader wants to acquire shares), SELL = 1 (trader wants to dispose of shares).
    enum Side {
        BUY,
        SELL
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Canonical order payload that traders sign via EIP-712.
    /// @dev The struct fields are tightly packed for gas efficiency in `abi.encode` hashing.
    /// Orders are immutable once signed — partial fills are tracked separately in `filledShares`.
    /// @param trader Address of the trader who signed and owns this order.
    /// @param asset The asset market this order targets.
    /// @param epochId The epoch identifier this order is valid for.
    /// @param outcome The outcome (UP or DOWN) this order trades.
    /// @param side Whether the trader is buying or selling outcome shares.
    /// @param priceBps Limit price in basis points [1, 9999]. Represents cost per share as a fraction of 1 unit.
    /// @param shares Total number of shares the order is willing to trade.
    /// @param expiry Unix timestamp after which the order is no longer valid.
    /// @param nonce Unique nonce to prevent replay attacks and enable bulk cancellation.
    /// @param salt Random salt to ensure order hash uniqueness for identical parameters.
    struct Order {
        address trader;
        Asset asset;
        uint256 epochId;
        Outcome outcome;
        Side side;
        uint16 priceBps;
        uint128 shares;
        uint64 expiry;
        uint64 nonce;
        bytes32 salt;
    }

    /// @notice An order bundled with its EIP-712 signature for on-chain verification.
    /// @param order The order payload.
    /// @param signature The EIP-712 signature (65 bytes: r, s, v) over the order's typed data hash.
    struct SignedOrder {
        Order order;
        bytes signature;
    }

    /// @notice Snapshot of a single epoch for one asset, tracking its full lifecycle.
    /// @dev Stored in `epochs[asset][epochId]`. An epoch with `endTs == 0` is considered non-existent.
    /// @param startTs Unix timestamp when the epoch's trading window opens (inclusive).
    /// @param endTs Unix timestamp when the epoch's trading window closes (exclusive).
    /// @param startRoundId Oracle round ID at epoch creation, used as the reference start price snapshot.
    /// @param finalRoundId Oracle round ID used for resolution. Zero until the epoch is resolved.
    /// @param startPrice Asset price at epoch start, used as the baseline for UP/DOWN determination.
    /// @param finalPrice Asset price at resolution time. Zero until the epoch is resolved.
    /// @param resolved Whether the epoch has been resolved with a winning outcome.
    /// @param winningOutcome The winning outcome after resolution. Only meaningful when `resolved == true`.
    struct Epoch {
        uint64 startTs;
        uint64 endTs;
        uint80 startRoundId;
        uint80 finalRoundId;
        int192 startPrice;
        int192 finalPrice;
        bool resolved;
        Outcome winningOutcome;
    }

    /// @notice Latest oracle price snapshot pushed on-chain by the owner.
    /// @dev The contract uses an owner-fed oracle model. The owner is responsible for
    /// pushing price updates from an external oracle (e.g., Chainlink) via `pushPrice()`.
    /// @param roundId Oracle round identifier for ordering and monotonicity checks.
    /// @param price Asset price with 8 decimal precision (e.g., 100_000e8 for $100,000).
    /// @param updatedAt Unix timestamp when this price was observed at the oracle source.
    struct PriceData {
        uint80 roundId;
        int192 price;
        uint256 updatedAt;
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Thrown when a zero address is provided where a valid address is required.
    error InvalidAddress();

    /// @notice Thrown when an amount parameter is zero or otherwise invalid.
    error InvalidAmount();

    /// @notice Thrown when an asset enum value is out of the valid range.
    error InvalidAsset();

    /// @notice Thrown when an order fails structural validation (mismatched sides, missing fields, etc.).
    error InvalidOrder();

    /// @notice Thrown when ECDSA signature recovery does not match the order's declared trader.
    error InvalidSignature();

    /// @notice Thrown when a price in basis points is zero or >= 10,000 (out of valid range).
    error InvalidPrice();

    /// @notice Thrown when referencing a non-existent epoch (`endTs == 0`).
    error InvalidEpoch();

    /// @notice Thrown when attempting to trade or mint in an epoch whose trading window has closed.
    error EpochEnded();

    /// @notice Thrown when attempting to resolve an epoch before its trading window has closed.
    error EpochNotEnded();

    /// @notice Thrown when attempting to resolve an epoch that has already been resolved.
    error EpochAlreadyResolved();

    /// @notice Thrown when attempting to claim from an epoch that has not yet been resolved.
    error EpochNotResolved();

    /// @notice Thrown when attempting to roll or resolve an epoch that is still within its active trading window.
    error EpochActive();

    /// @notice Thrown when a trader's free collateral is insufficient to cover a trade or mint operation.
    error InsufficientCollateral();

    /// @notice Thrown when a trader lacks enough outcome shares for a sell or merge operation.
    error InsufficientShares();

    /// @notice Thrown when an order's expiry timestamp has passed.
    error OrderExpired();

    /// @notice Thrown when attempting to fill an order that has been explicitly cancelled.
    error OrderIsCancelled();

    /// @notice Thrown when a fill request exceeds the order's remaining unfilled shares.
    error OrderOverfilled();

    /// @notice Thrown when the oracle round ID is zero (no price data has been pushed yet).
    error OracleRoundIncomplete();

    /// @notice Thrown when the oracle price is zero or negative.
    error OraclePriceInvalid();

    /// @notice Thrown when oracle timestamp validation fails (zero, future, or stale).
    error OracleTimestampInvalid();

    /// @notice Thrown when a claim attempt finds zero winning shares for the caller.
    error NothingToClaim();

    /// @notice Thrown when `cancelOrder()` is called by someone who does not own the order hash.
    error OrderOwnerMismatch();

    /// @notice Thrown when taker/maker fill arrays have mismatched lengths in `matchOrdersPolymarketStyle()`.
    error FillArrayLengthMismatch();

    /// @notice Thrown when matched orders do not cross (buy price < sell price).
    error NotCrossing();

    /// @notice Thrown when matched orders target different outcomes.
    error MismatchedOutcomes();

    /// @notice Thrown when a non-matcher, non-owner address attempts to execute matches.
    error UnauthorizedMatcher();

    /// @notice Thrown when a uint256 value exceeds the uint64 range during timestamp calculations.
    error TimestampOverflow();

    /// @notice Thrown when a native ETH transfer fails (recipient reverted or ran out of gas).
    error NativeTransferFailed();

    /// @notice Thrown when `bootstrapDailyEpochs()` is called more than once.
    error MarketsAlreadyBootstrapped();

    /// @notice Thrown when epoch operations are attempted before markets have been bootstrapped.
    error MarketsNotBootstrapped();

    /// @notice Thrown when a nonce value is invalid for `cancelAllUpTo()` (must be strictly increasing).
    error InvalidNonce();

    /// @notice Thrown when the oracle price timestamp does not fall within the current UTC day during bootstrap.
    error PriceNotInCurrentUtcDay();

    /// @notice Thrown when a non-treasury, non-owner address attempts mint or merge operations.
    error UnauthorizedTreasury();

    // ──────────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when a user deposits native collateral into their free balance.
    /// @param user The address that deposited collateral.
    /// @param amount The amount of native currency deposited (in wei).
    event Deposited(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws native collateral from their free balance.
    /// @param user The address that withdrew collateral.
    /// @param amount The amount of native currency withdrawn (in wei).
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when the treasury mints paired UP/DOWN outcome shares for an epoch.
    /// @param user The treasury address that performed the mint.
    /// @param asset The asset market the shares were minted for.
    /// @param epochId The epoch the shares belong to.
    /// @param amount The number of share pairs minted (1 UP + 1 DOWN per unit).
    event Minted(address indexed user, Asset indexed asset, uint256 indexed epochId, uint256 amount);

    /// @notice Emitted when the treasury merges paired UP/DOWN shares back into collateral.
    /// @param user The treasury address that performed the merge.
    /// @param asset The asset market the shares were merged from.
    /// @param epochId The epoch the shares belonged to.
    /// @param shares The number of share pairs merged (1 UP + 1 DOWN burned per unit).
    event Merged(address indexed user, Asset indexed asset, uint256 indexed epochId, uint256 shares);

    /// @notice Emitted when a user redeems winning outcome shares after epoch resolution.
    /// @param user The address claiming the payout.
    /// @param asset The asset market of the resolved epoch.
    /// @param epochId The resolved epoch identifier.
    /// @param winner The winning outcome that was claimed.
    /// @param payout The amount of native currency paid out (in wei).
    event Claimed(address indexed user, Asset indexed asset, uint256 indexed epochId, Outcome winner, uint256 payout);

    /// @notice Emitted when an order is cancelled by its owner.
    /// @param orderHash The EIP-712 digest of the cancelled order.
    /// @param trader The address that cancelled the order.
    event OrderCancelled(bytes32 indexed orderHash, address indexed trader);

    /// @notice Emitted for each successful fill during order matching.
    /// @param takerOrderHash The EIP-712 digest of the taker order.
    /// @param makerOrderHash The EIP-712 digest of the matched maker order.
    /// @param buyer The address on the buy side of the trade.
    /// @param seller The address on the sell side of the trade.
    /// @param asset The asset market where the trade occurred.
    /// @param epochId The epoch where the trade occurred.
    /// @param outcome The outcome being traded (UP or DOWN).
    /// @param fillShares The number of shares exchanged in this fill.
    /// @param tradePriceBps The execution price in basis points (seller's limit price).
    /// @param notional The quote amount transferred from buyer to seller (in wei).
    event OrdersMatched(
        bytes32 indexed takerOrderHash,
        bytes32 indexed makerOrderHash,
        address indexed buyer,
        address seller,
        Asset asset,
        uint256 epochId,
        Outcome outcome,
        uint256 fillShares,
        uint256 tradePriceBps,
        uint256 notional
    );

    /// @notice Emitted when the owner pushes a new oracle price for an asset.
    /// @param asset The asset whose price was updated.
    /// @param roundId The oracle round identifier.
    /// @param price The new price value (8 decimal precision).
    /// @param updatedAt The timestamp when the price was observed.
    event PriceUpdated(Asset indexed asset, uint80 roundId, int192 price, uint256 updatedAt);

    /// @notice Emitted when a new epoch is created for an asset.
    /// @param asset The asset the epoch belongs to.
    /// @param epochId The sequential epoch identifier.
    /// @param startTs The epoch start timestamp (inclusive).
    /// @param endTs The epoch end timestamp (exclusive).
    /// @param startPrice The oracle price at epoch creation.
    /// @param roundId The oracle round ID at epoch creation.
    event EpochCreated(Asset indexed asset, uint256 indexed epochId, uint64 startTs, uint64 endTs, int192 startPrice, uint80 roundId);

    /// @notice Emitted when an epoch is resolved with a winning outcome.
    /// @param asset The asset whose epoch was resolved.
    /// @param epochId The resolved epoch identifier.
    /// @param winningOutcome The determined winning outcome (UP or DOWN).
    /// @param finalPrice The oracle price used for resolution.
    /// @param roundId The oracle round ID used for resolution.
    event EpochResolved(Asset indexed asset, uint256 indexed epochId, Outcome winningOutcome, int192 finalPrice, uint80 roundId);

    /// @notice Emitted when the matcher address is updated.
    /// @param matcher The new matcher address.
    event MatcherUpdated(address indexed matcher);

    /// @notice Emitted when the maximum oracle price age is updated.
    /// @param maxPriceAge The new maximum acceptable price age in seconds.
    event MaxPriceAgeUpdated(uint256 maxPriceAge);

    /// @notice Emitted when all asset markets are bootstrapped for the first time.
    /// @param dayStartTs The UTC day-start timestamp used to align the first epochs.
    event MarketsBootstrapped(uint64 indexed dayStartTs);

    /// @notice Emitted when a trader cancels a specific nonce.
    /// @param trader The address that cancelled the nonce.
    /// @param nonce The cancelled nonce value.
    event NonceCancelled(address indexed trader, uint64 nonce);

    /// @notice Emitted when a trader bulk-cancels all nonces below a new minimum.
    /// @param trader The address that updated their minimum valid nonce.
    /// @param minValidNonce The new minimum valid nonce floor.
    event MinValidNonceUpdated(address indexed trader, uint64 minValidNonce);

    /// @notice Emitted when the treasury address is updated.
    /// @param treasury The new treasury address.
    event TreasuryUpdated(address indexed treasury);

    // ──────────────────────────────────────────────────────────────────────────────
    // State Variables
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Address authorized to submit order matches alongside the owner.
    /// @dev Typically a backend bot that discovers order crosses off-chain and submits
    /// them for on-chain settlement. Can be rotated by the owner via `setMatcher()`.
    address public matcherAddress;

    /// @notice Address holding house inventory and authorized for mint/merge operations.
    /// @dev The treasury deposits collateral, mints paired shares, and acts as the primary
    /// market maker. Can be rotated by the owner via `setTreasury()`.
    address public treasury;

    /// @notice Maximum acceptable age (in seconds) for oracle price data.
    /// @dev Used in `_readLatestPrice()` to reject stale prices. Defaults to `DEFAULT_MAX_PRICE_AGE`.
    uint256 public maxPriceAge;

    /// @notice Whether `bootstrapDailyEpochs()` has been called to initialize the first epochs.
    /// @dev Set to `true` once during bootstrap. Prevents re-initialization.
    bool public marketsBootstrapped;

    /// @notice Latest oracle price snapshot per asset, pushed by the owner.
    /// @dev Maps `Asset => PriceData`. Updated monotonically via `pushPrice()`.
    mapping(Asset => PriceData) public latestPrices;

    /// @notice Current (latest) epoch ID per asset.
    /// @dev Starts at 1 after bootstrap and increments by 1 on each `rollDaily()`.
    mapping(Asset => uint256) public latestEpochId;

    /// @notice Full epoch state for each asset and epoch ID.
    /// @dev Maps `Asset => epochId => Epoch`. An epoch with `endTs == 0` does not exist.
    mapping(Asset => mapping(uint256 => Epoch)) public epochs;

    /// @notice Total collateral locked in escrow for each asset/epoch, backing outstanding shares.
    /// @dev Maps `Asset => epochId => escrowed amount`. Increased by mints, decreased by merges and claims.
    mapping(Asset => mapping(uint256 => uint256)) public epochEscrow;

    /// @notice Unencumbered native collateral balance per user, available for trading or withdrawal.
    /// @dev Increased by deposits and sell-side trade proceeds. Decreased by withdrawals, mints, and buy-side fills.
    mapping(address => uint256) public freeCollateral;

    /// @notice Conditional outcome share balances per user, asset, epoch, and outcome.
    /// @dev Maps `user => Asset => epochId => Outcome => share count`. Shares are fungible within
    /// the same (asset, epoch, outcome) tuple.
    mapping(address => mapping(Asset => mapping(uint256 => mapping(Outcome => uint256)))) public outcomeShares;

    /// @notice Cumulative filled shares per order hash, tracking partial fill progress.
    /// @dev Maps `order EIP-712 digest => total shares filled so far`.
    mapping(bytes32 => uint256) public filledShares;

    /// @notice Whether an order hash has been explicitly cancelled.
    /// @dev Maps `order EIP-712 digest => cancelled flag`.
    mapping(bytes32 => bool) public cancelledOrders;

    /// @notice Maps each order hash to the trader address that first used it.
    /// @dev Binds ownership on first verification to prevent cancellation hijacking.
    mapping(bytes32 => address) public orderOwner;

    /// @notice Per-trader, per-nonce cancellation flags for selective nonce invalidation.
    /// @dev Maps `trader => nonce => cancelled flag`. Set via `cancelNonce()`.
    mapping(address => mapping(uint64 => bool)) public cancelledNonces;

    /// @notice Minimum valid nonce per trader for bulk cancellation.
    /// @dev Any order with `nonce < minValidNonce[trader]` is considered cancelled.
    /// Set via `cancelAllUpTo()` and must be strictly increasing.
    mapping(address => uint64) public minValidNonce;

    // ──────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Locks the implementation contract to prevent direct initialization.
    /// @dev Only proxy instances should be initialized via `initialize()`. This follows
    /// the OpenZeppelin UUPS pattern where the implementation's constructor disables
    /// initializers to prevent the implementation itself from being used directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Initializer
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Initializes the proxy instance with owner, matcher, and all upgradeable module state.
    /// @dev Can only be called once (enforced by the `initializer` modifier). Sets up:
    ///   - Ownable with `initialOwner` as the contract owner
    ///   - EIP-712 domain separator with name "PredictionMarket" and version "1"
    ///   - Pausable module
    ///   - Matcher address for order settlement authorization
    ///   - Treasury defaults to `initialOwner` (can be changed via `setTreasury()`)
    ///   - `maxPriceAge` defaults to `DEFAULT_MAX_PRICE_AGE`
    /// @param initialOwner The address to set as the contract owner (must not be zero).
    /// @param initialMatcher The address authorized to execute order matches (must not be zero).
    function initialize(address initialOwner, address initialMatcher) external initializer {
        if (initialOwner == address(0) || initialMatcher == address(0)) revert InvalidAddress();

        __Ownable_init(initialOwner);
        __EIP712_init("PredictionMarket", "1");
        __Pausable_init();
        matcherAddress = initialMatcher;
        treasury = initialOwner;
        maxPriceAge = DEFAULT_MAX_PRICE_AGE;
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Restricts access to the matcher bot or the contract owner.
    /// @dev Used on `matchOrdersPolymarketStyle()` to allow automated settlement while
    /// maintaining owner override capability.
    modifier onlyMatcherOrOwner() {
        if (msg.sender != owner() && msg.sender != matcherAddress) revert UnauthorizedMatcher();
        _;
    }

    /// @notice Restricts access to the treasury or the contract owner.
    /// @dev Used on `mint()` and `merge()` to allow the treasury to manage share issuance
    /// while maintaining owner override capability.
    modifier onlyOwnerOrTreasury() {
        if (msg.sender != owner() && msg.sender != treasury) revert UnauthorizedTreasury();
        _;
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Authorizes a UUPS upgrade to a new implementation contract.
    /// @dev Restricted to the contract owner. The `newImplementation` parameter is unused
    /// but required by the UUPS interface — any valid contract address is accepted.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Rotates the matcher address used for order settlement authorization.
    /// @dev Only callable by the contract owner. The matcher is typically a backend bot
    /// that discovers order crosses off-chain and submits them for on-chain execution.
    /// @param newMatcher The new matcher address (must not be zero).
    function setMatcher(address newMatcher) external onlyOwner {
        if (newMatcher == address(0)) revert InvalidAddress();
        matcherAddress = newMatcher;
        emit MatcherUpdated(newMatcher);
    }

    /// @notice Rotates the treasury address that holds and operates house inventory.
    /// @dev Only callable by the contract owner. Changing the treasury does NOT migrate
    /// existing collateral or share balances — those remain under the old address.
    /// @param newTreasury The new treasury address (must not be zero).
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @notice Updates the maximum acceptable oracle price age for freshness checks.
    /// @dev Only callable by the contract owner. Setting this too low may cause
    /// resolutions to fail if oracle updates are delayed. Setting it too high
    /// risks using stale prices for settlement.
    /// @param newMaxPriceAge The new maximum price age in seconds (must be > 0).
    function setMaxPriceAge(uint256 newMaxPriceAge) external onlyOwner {
        if (newMaxPriceAge == 0) revert InvalidAmount();
        maxPriceAge = newMaxPriceAge;
        emit MaxPriceAgeUpdated(newMaxPriceAge);
    }

    /// @notice Pauses all mutable user-facing operations (deposits, withdrawals, trades, claims).
    /// @dev Only callable by the contract owner. Emergency circuit breaker. Admin functions
    /// (pushPrice, resolve, roll) are NOT affected by pause state.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes all mutable user-facing operations after a pause.
    /// @dev Only callable by the contract owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Oracle Functions
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Pushes a new oracle price snapshot for an asset.
    /// @dev Only callable by the contract owner. Enforces strict monotonicity on both
    /// `roundId` and `updatedAt` to prevent stale or out-of-order updates. The contract
    /// uses an owner-fed oracle model: the owner reads from an external source (e.g.,
    /// Chainlink) and relays the data on-chain.
    /// @param asset The asset to update the price for.
    /// @param roundId The oracle round identifier (must be strictly greater than the current round).
    /// @param price The new price value (must be > 0, typically 8 decimal precision).
    /// @param updatedAt The timestamp when this price was observed (must be <= `block.timestamp`).
    function pushPrice(Asset asset, uint80 roundId, int192 price, uint256 updatedAt) external onlyOwner {
        _validateAsset(asset);
        if (price <= 0) revert OraclePriceInvalid();
        if (updatedAt == 0 || updatedAt > block.timestamp) revert OracleTimestampInvalid();

        PriceData storage current = latestPrices[asset];
        if (current.roundId != 0) {
            if (roundId <= current.roundId) revert OracleRoundIncomplete();
            if (updatedAt < current.updatedAt) revert OracleTimestampInvalid();
        }

        latestPrices[asset] = PriceData({roundId: roundId, price: price, updatedAt: updatedAt});
        emit PriceUpdated(asset, roundId, price, updatedAt);
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Epoch Lifecycle Functions
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Bootstraps the first daily epoch for all supported assets.
    /// @dev Only callable once by the contract owner. Creates epoch ID 1 for BTC, ETH, and DOT,
    /// aligned to the current UTC day boundary. Requires that oracle prices have been pushed
    /// for all assets and that each price falls within the current UTC day window.
    function bootstrapDailyEpochs() external onlyOwner {
        if (marketsBootstrapped) revert MarketsAlreadyBootstrapped();

        uint64 dayStart = _dayStartUtc(block.timestamp);
        uint64 duration = _toUint64(EPOCH_DURATION);
        if (dayStart > type(uint64).max - duration) revert TimestampOverflow();
        uint64 dayEnd = dayStart + duration;

        for (uint8 i = 0; i <= uint8(Asset.DOT); ++i) {
            Asset asset = Asset(i);
            (uint80 roundId, int192 startPrice, uint256 updatedAt) = _readLatestPrice(asset);
            if (updatedAt < dayStart || updatedAt >= dayEnd) revert PriceNotInCurrentUtcDay();
            _createEpoch(asset, 1, dayStart, roundId, startPrice);
            latestEpochId[asset] = 1;
        }

        marketsBootstrapped = true;
        emit MarketsBootstrapped(dayStart);
    }

    /// @notice Rolls a single asset to its next daily epoch.
    /// @dev Only callable by the contract owner. If the current epoch is unresolved but past
    /// its end time, it will be automatically resolved before creating the next epoch. The new
    /// epoch starts exactly where the previous one ended, forming a contiguous timeline.
    /// @param asset The asset to roll forward.
    function rollDaily(Asset asset) external onlyOwner {
        _rollDaily(asset);
    }

    /// @notice Convenience function to roll all supported assets (BTC, ETH, DOT) to their next epochs.
    /// @dev Only callable by the contract owner. Calls `_rollDaily()` sequentially for each asset.
    function rollDailyAll() external onlyOwner {
        _rollDaily(Asset.BTC);
        _rollDaily(Asset.ETH);
        _rollDaily(Asset.DOT);
    }

    /// @notice Explicitly resolves a specific epoch for a given asset.
    /// @dev Only callable by the contract owner. The epoch must exist and be past its end time.
    /// Resolution determines the winning outcome by comparing the start price to the latest
    /// oracle price. A fresh oracle price (posted after the epoch ended) is required.
    /// @param asset The asset whose epoch to resolve.
    /// @param epochId The epoch identifier to resolve.
    function resolveEpoch(Asset asset, uint256 epochId) external onlyOwner {
        _validateAsset(asset);
        Epoch storage epoch = epochs[asset][epochId];
        if (epoch.endTs == 0) revert InvalidEpoch();
        _resolveEpoch(asset, epochId, epoch);
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Collateral Functions
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Deposits native currency (ETH) as free collateral for the caller.
    /// @dev The deposited amount becomes immediately available for trading (buying shares)
    /// or minting operations (if caller is treasury). Protected against reentrancy.
    function depositCollateral() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert InvalidAmount();
        freeCollateral[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Withdraws unencumbered free collateral back to the caller.
    /// @dev Only withdraws from `freeCollateral` — collateral locked in epoch escrow or
    /// committed to open positions cannot be withdrawn. Protected against reentrancy.
    /// @param amount The amount of native currency to withdraw (in wei, must be > 0).
    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (freeCollateral[msg.sender] < amount) revert InsufficientCollateral();

        freeCollateral[msg.sender] -= amount;
        _sendNative(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Share Issuance Functions
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Mints paired UP and DOWN outcome shares for a given epoch, backed by treasury collateral.
    /// @dev Only callable by the treasury or owner. Locks `amount` from treasury's free collateral
    /// into epoch escrow, then credits the treasury with `amount` UP shares and `amount` DOWN shares.
    /// This creates balanced inventory that the treasury can sell on the orderbook.
    /// @param asset The asset market to mint shares for.
    /// @param epochId The epoch to mint shares in (must be active and unresolved).
    /// @param amount The number of share pairs to mint, also the collateral amount to lock (in wei).
    function mint(Asset asset, uint256 epochId, uint256 amount) external onlyOwnerOrTreasury nonReentrant whenNotPaused {
        _mint(asset, epochId, amount);
    }

    /// @notice Burns paired UP and DOWN shares held by the treasury to unlock escrowed collateral.
    /// @dev Only callable by the treasury or owner. The inverse of `mint()`: burns `shares` UP and
    /// `shares` DOWN from the treasury's balance and returns the equivalent collateral to treasury's
    /// free balance. The epoch must not yet be resolved.
    /// @param asset The asset market to merge shares from.
    /// @param epochId The epoch to merge shares in (must exist and not be resolved).
    /// @param shares The number of share pairs to merge/burn.
    function merge(Asset asset, uint256 epochId, uint256 shares) external onlyOwnerOrTreasury nonReentrant whenNotPaused {
        _validateAsset(asset);
        if (shares == 0) revert InvalidAmount();

        Epoch storage epoch = epochs[asset][epochId];
        if (epoch.endTs == 0) revert InvalidEpoch();
        if (epoch.resolved) revert EpochAlreadyResolved();

        uint256 upShares = outcomeShares[treasury][asset][epochId][Outcome.UP];
        uint256 downShares = outcomeShares[treasury][asset][epochId][Outcome.DOWN];
        if (upShares < shares || downShares < shares) revert InsufficientShares();
        if (epochEscrow[asset][epochId] < shares) revert InsufficientCollateral();

        outcomeShares[treasury][asset][epochId][Outcome.UP] -= shares;
        outcomeShares[treasury][asset][epochId][Outcome.DOWN] -= shares;

        epochEscrow[asset][epochId] -= shares;
        freeCollateral[treasury] += shares;

        emit Merged(treasury, asset, epochId, shares);
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Claim Function
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Redeems winning outcome shares for native collateral after an epoch is resolved.
    /// @dev Each winning share redeems exactly 1 unit of collateral from the epoch's escrow pool.
    /// Losing shares are worthless and remain in the user's balance (they can be ignored).
    /// Protected against reentrancy.
    /// @param asset The asset market of the resolved epoch.
    /// @param epochId The resolved epoch to claim winnings from.
    function claim(Asset asset, uint256 epochId) external nonReentrant whenNotPaused {
        _validateAsset(asset);

        Epoch storage epoch = epochs[asset][epochId];
        if (epoch.endTs == 0) revert InvalidEpoch();
        if (!epoch.resolved) revert EpochNotResolved();

        Outcome winner = epoch.winningOutcome;
        uint256 winningShares = outcomeShares[msg.sender][asset][epochId][winner];
        if (winningShares == 0) revert NothingToClaim();

        outcomeShares[msg.sender][asset][epochId][winner] = 0;

        uint256 payout = winningShares;
        if (epochEscrow[asset][epochId] < payout) revert InsufficientCollateral();
        epochEscrow[asset][epochId] -= payout;

        _sendNative(msg.sender, payout);
        emit Claimed(msg.sender, asset, epochId, winner, payout);
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Order Matching
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Matches a taker order against one or more maker orders, executing atomic on-chain settlement.
    /// @dev Only callable by the matcher bot or owner. Implements Polymarket-style order matching:
    ///   1. Validates and recovers the taker's EIP-712 signature
    ///   2. For each maker, validates signatures, checks crossing conditions, and executes fills
    ///   3. Each fill atomically transfers collateral (buyer -> seller) and shares (seller -> buyer)
    ///   4. Trade price is the seller's limit price (price improvement goes to the buyer)
    ///
    /// Requirements:
    ///   - Taker and each maker must target the same (asset, epochId, outcome)
    ///   - Taker and each maker must be on opposite sides (one BUY, one SELL)
    ///   - Orders must cross: `buy.priceBps >= sell.priceBps`
    ///   - The epoch must be active (not ended, not resolved)
    ///   - All signatures must be valid and orders must not be cancelled or expired
    ///
    /// @param taker The signed taker order initiating the match.
    /// @param makers Array of signed maker orders to match against.
    /// @param takerFillShares Maximum shares to fill for the taker across all makers.
    /// @param makerFillShares Per-maker fill caps (must have same length as `makers`).
    function matchOrdersPolymarketStyle(
        SignedOrder calldata taker,
        SignedOrder[] calldata makers,
        uint128 takerFillShares,
        uint128[] calldata makerFillShares
    ) external nonReentrant whenNotPaused onlyMatcherOrOwner {
        if (makers.length != makerFillShares.length) revert FillArrayLengthMismatch();
        if (takerFillShares == 0) revert InvalidAmount();

        Order calldata takerOrder = taker.order;
        bytes32 takerOrderHash = _verifyAndHashOrderAny(takerOrder, taker.signature);
        if (cancelledOrders[takerOrderHash]) revert OrderIsCancelled();

        Epoch storage epoch = epochs[takerOrder.asset][takerOrder.epochId];
        if (epoch.endTs == 0 || epoch.resolved) revert InvalidEpoch();
        if (block.timestamp >= epoch.endTs) revert EpochEnded();

        uint256 takerRemaining = uint256(takerOrder.shares) - filledShares[takerOrderHash];
        uint256 takerToFill = uint256(takerFillShares);
        if (takerToFill > takerRemaining) revert OrderOverfilled();

        for (uint256 i = 0; i < makers.length; ++i) {
            if (takerToFill == 0) break;

            SignedOrder calldata makerSigned = makers[i];
            Order calldata makerOrder = makerSigned.order;
            bytes32 makerOrderHash = _verifyAndHashOrderAny(makerOrder, makerSigned.signature);
            if (cancelledOrders[makerOrderHash]) revert OrderIsCancelled();

            _validatePairCompatibility(takerOrder, makerOrder);
            if (!_isCrossing(takerOrder, makerOrder)) revert NotCrossing();

            uint256 makerRemaining = uint256(makerOrder.shares) - filledShares[makerOrderHash];
            uint256 makerRequested = uint256(makerFillShares[i]);
            uint256 fillShares = _min3(takerToFill, makerRemaining, makerRequested);
            if (fillShares == 0) continue;

            _executeTrade(takerOrder, makerOrder, fillShares);

            filledShares[takerOrderHash] += fillShares;
            filledShares[makerOrderHash] += fillShares;
            takerToFill -= fillShares;

            (Order calldata buy, Order calldata sell) = _asBuySell(takerOrder, makerOrder);
            uint256 notional = _notional(fillShares, sell.priceBps);

            emit OrdersMatched(
                takerOrderHash,
                makerOrderHash,
                buy.trader,
                sell.trader,
                buy.asset,
                buy.epochId,
                buy.outcome,
                fillShares,
                sell.priceBps,
                notional
            );
        }
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Order Cancellation Functions
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Cancels a specific order by its EIP-712 digest hash.
    /// @dev Only the original signer (bound via `orderOwner` mapping) can cancel.
    /// The order must have been previously verified on-chain for the ownership binding to exist.
    /// @param orderHash The EIP-712 typed data hash of the order to cancel.
    function cancelOrder(bytes32 orderHash) external {
        if (orderOwner[orderHash] != msg.sender) revert OrderOwnerMismatch();
        cancelledOrders[orderHash] = true;
        emit OrderCancelled(orderHash, msg.sender);
    }

    /// @notice Cancels a single nonce, invalidating any order using this nonce.
    /// @dev Soft cancellation — only affects the specific nonce without impacting other orders.
    /// Useful for cancelling a known pending order without needing the full order hash.
    /// @param nonce The nonce value to invalidate.
    function cancelNonce(uint64 nonce) external {
        cancelledNonces[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    /// @notice Bulk-cancels all orders with nonces below a new minimum threshold.
    /// @dev The new minimum must be strictly greater than the current minimum. This provides
    /// an efficient way to invalidate all historical orders in a single transaction.
    /// @param newMinValidNonce The new minimum valid nonce floor (must be > current minimum).
    function cancelAllUpTo(uint64 newMinValidNonce) external {
        uint64 current = minValidNonce[msg.sender];
        if (newMinValidNonce <= current) revert InvalidNonce();
        minValidNonce[msg.sender] = newMinValidNonce;
        emit MinValidNonceUpdated(msg.sender, newMinValidNonce);
    }

    /// @notice Cancels an order using its full payload and signature, without needing the digest.
    /// @dev Useful when the trader does not track order hashes off-chain. The caller must be
    /// the order's declared trader. The signature is verified to derive the correct order hash.
    /// @param order The full order payload to cancel.
    /// @param signature The EIP-712 signature over the order.
    function cancelOrderBySig(Order calldata order, bytes calldata signature) external {
        if (order.trader != msg.sender) revert OrderOwnerMismatch();
        bytes32 orderHash = _verifyAndHashOrderAny(order, signature);
        cancelledOrders[orderHash] = true;
        emit OrderCancelled(orderHash, msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // View / Pure Helpers
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Computes the EIP-712 typed data hash for an order, suitable for off-chain signing.
    /// @dev Traders should sign this hash using `eth_signTypedData_v4` with the contract's domain separator.
    /// @param order The order to compute the hash for.
    /// @return The EIP-712 digest that should be signed by the trader.
    function hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_orderStructHash(order));
    }

    /// @notice Computes the notional (quote) value for a given number of shares at a given price.
    /// @dev Useful for UIs to preview trade costs before signing orders.
    /// Formula: `notional = shares * priceBps / 10,000`.
    /// @param shares The number of outcome shares.
    /// @param priceBps The price in basis points [1, 9999].
    /// @return The notional value in the same denomination as shares (wei).
    function previewNotional(uint256 shares, uint16 priceBps) external pure returns (uint256) {
        if (priceBps == 0 || priceBps >= PRICE_BPS_DENOMINATOR) revert InvalidPrice();
        return _notional(shares, priceBps);
    }

    /// @notice Returns the current (latest) epoch ID and full epoch data for an asset.
    /// @param asset The asset to query.
    /// @return epochId The latest epoch identifier.
    /// @return epoch The full epoch struct.
    function getCurrentEpoch(Asset asset) external view returns (uint256 epochId, Epoch memory epoch) {
        _validateAsset(asset);
        epochId = latestEpochId[asset];
        epoch = epochs[asset][epochId];
    }

    /// @notice Returns the full epoch data for a specific asset and epoch ID.
    /// @param asset The asset to query.
    /// @param epochId The epoch identifier to look up.
    /// @return The full epoch struct. An epoch with `endTs == 0` does not exist.
    function getEpoch(Asset asset, uint256 epochId) external view returns (Epoch memory) {
        _validateAsset(asset);
        return epochs[asset][epochId];
    }

    /// @notice Returns a user's UP and DOWN share balances for a specific asset and epoch.
    /// @param user The address to query share balances for.
    /// @param asset The asset market to query.
    /// @param epochId The epoch to query.
    /// @return up The number of UP outcome shares held.
    /// @return down The number of DOWN outcome shares held.
    function getUserShares(address user, Asset asset, uint256 epochId) external view returns (uint256 up, uint256 down) {
        _validateAsset(asset);
        up = outcomeShares[user][asset][epochId][Outcome.UP];
        down = outcomeShares[user][asset][epochId][Outcome.DOWN];
    }

    /// @notice Returns a user's unencumbered free collateral balance.
    /// @param user The address to query.
    /// @return The free collateral balance in wei.
    function getFreeCollateral(address user) external view returns (uint256) {
        return freeCollateral[user];
    }

    /// @notice Returns the latest oracle price snapshot for an asset.
    /// @param asset The asset to query.
    /// @return The latest `PriceData` struct. A `roundId` of 0 means no price has been pushed.
    function getLatestPrice(Asset asset) external view returns (PriceData memory) {
        _validateAsset(asset);
        return latestPrices[asset];
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Internal Functions
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Resolves an epoch by comparing its start price to the latest oracle price.
    /// @dev Determines the winning outcome:
    ///   - `finalPrice > startPrice` -> UP wins
    ///   - `finalPrice < startPrice` -> DOWN wins
    ///   - `finalPrice == startPrice` -> Deterministic tie-breaker using `roundId % 2`
    ///     (even -> DOWN, odd -> UP) to avoid unresolvable draw states
    ///
    /// Requires a fresh oracle price posted after the epoch's end time.
    /// @param asset The asset being resolved.
    /// @param epochId The epoch identifier being resolved.
    /// @param epoch Storage pointer to the epoch struct.
    function _resolveEpoch(Asset asset, uint256 epochId, Epoch storage epoch) internal {
        if (epoch.resolved) revert EpochAlreadyResolved();
        if (block.timestamp < epoch.endTs) revert EpochNotEnded();

        (uint80 roundId, int192 finalPrice, uint256 updatedAt) = _readLatestPrice(asset);
        if (updatedAt < epoch.endTs) revert OracleTimestampInvalid();

        Outcome winner;
        if (finalPrice > epoch.startPrice) {
            winner = Outcome.UP;
        } else if (finalPrice < epoch.startPrice) {
            winner = Outcome.DOWN;
        } else {
            winner = (roundId % 2 == 0) ? Outcome.DOWN : Outcome.UP;
        }

        epoch.finalRoundId = roundId;
        epoch.finalPrice = finalPrice;
        epoch.winningOutcome = winner;
        epoch.resolved = true;

        emit EpochResolved(asset, epochId, winner, finalPrice, roundId);
    }

    /// @notice Creates a new epoch with a deterministic `[startTs, startTs + EPOCH_DURATION)` window.
    /// @dev Initializes all epoch fields with the start snapshot and default unresolved state.
    /// @param asset The asset to create the epoch for.
    /// @param epochId The sequential epoch identifier.
    /// @param startTs The epoch start timestamp (UTC day boundary).
    /// @param startRoundId The oracle round ID at epoch creation.
    /// @param startPrice The oracle price at epoch creation.
    function _createEpoch(Asset asset, uint256 epochId, uint64 startTs, uint80 startRoundId, int192 startPrice) internal {
        uint64 duration = _toUint64(EPOCH_DURATION);
        if (startTs > type(uint64).max - duration) revert TimestampOverflow();
        uint64 endTs = startTs + duration;

        epochs[asset][epochId] = Epoch({
            startTs: startTs,
            endTs: endTs,
            startRoundId: startRoundId,
            finalRoundId: 0,
            startPrice: startPrice,
            finalPrice: 0,
            resolved: false,
            winningOutcome: Outcome.DOWN
        });

        emit EpochCreated(asset, epochId, startTs, endTs, startPrice, startRoundId);
    }

    /// @notice Rolls market state forward by one epoch for a single asset.
    /// @dev If the current epoch is unresolved but past its end time, it is automatically
    /// resolved first. The new epoch starts at the previous epoch's end time, and inherits
    /// the final price/round as its start snapshot, forming a contiguous price timeline.
    /// @param asset The asset to roll forward.
    function _rollDaily(Asset asset) internal {
        _validateAsset(asset);

        uint256 currentEpochId = latestEpochId[asset];
        if (currentEpochId == 0) {
            revert MarketsNotBootstrapped();
        }

        Epoch storage currentEpoch = epochs[asset][currentEpochId];
        if (!currentEpoch.resolved) {
            if (block.timestamp < currentEpoch.endTs) revert EpochActive();
            _resolveEpoch(asset, currentEpochId, currentEpoch);
        } else if (block.timestamp < currentEpoch.endTs) {
            revert EpochActive();
        }

        uint256 newEpochId = currentEpochId + 1;
        uint64 nextStartTs = currentEpoch.endTs;
        _createEpoch(asset, newEpochId, nextStartTs, currentEpoch.finalRoundId, currentEpoch.finalPrice);
        latestEpochId[asset] = newEpochId;
    }

    /// @notice Executes a single fill between a buyer and seller, transferring collateral and shares atomically.
    /// @dev The trade price is the seller's limit price. The buyer pays
    /// `notional = fillShares * sell.priceBps / 10,000` from their free collateral,
    /// and the seller receives that amount. Shares move from seller to buyer.
    /// @param takerOrder The taker's order (either buy or sell side).
    /// @param makerOrder The maker's order (opposite side from taker).
    /// @param fillShares The number of shares to exchange in this fill.
    function _executeTrade(Order calldata takerOrder, Order calldata makerOrder, uint256 fillShares) internal {
        (Order calldata buy, Order calldata sell) = _asBuySell(takerOrder, makerOrder);

        uint256 notional = _notional(fillShares, sell.priceBps);
        if (freeCollateral[buy.trader] < notional) revert InsufficientCollateral();
        if (outcomeShares[sell.trader][sell.asset][sell.epochId][sell.outcome] < fillShares) revert InsufficientShares();

        freeCollateral[buy.trader] -= notional;
        freeCollateral[sell.trader] += notional;

        outcomeShares[sell.trader][sell.asset][sell.epochId][sell.outcome] -= fillShares;
        outcomeShares[buy.trader][buy.asset][buy.epochId][buy.outcome] += fillShares;
    }

    /// @notice Internal mint primitive: locks treasury collateral and issues balanced UP/DOWN shares.
    /// @dev The treasury's free collateral is reduced by `amount`, epoch escrow is increased by `amount`,
    /// and the treasury receives `amount` UP shares and `amount` DOWN shares. The epoch must be active.
    /// @param asset The asset market to mint shares for.
    /// @param epochId The epoch to mint shares in.
    /// @param amount The number of share pairs to mint (also the collateral to lock).
    function _mint(Asset asset, uint256 epochId, uint256 amount) internal {
        _validateAsset(asset);
        if (amount == 0) revert InvalidAmount();

        Epoch storage epoch = epochs[asset][epochId];
        if (epoch.endTs == 0) revert InvalidEpoch();
        if (epoch.resolved) revert EpochAlreadyResolved();
        if (block.timestamp >= epoch.endTs) revert EpochEnded();
        if (freeCollateral[treasury] < amount) revert InsufficientCollateral();

        freeCollateral[treasury] -= amount;
        epochEscrow[asset][epochId] += amount;

        outcomeShares[treasury][asset][epochId][Outcome.UP] += amount;
        outcomeShares[treasury][asset][epochId][Outcome.DOWN] += amount;

        emit Minted(treasury, asset, epochId, amount);
    }

    /// @notice Validates that two orders are compatible for matching.
    /// @dev Both orders must reference the same asset, epoch, and outcome, but must be on
    /// opposite sides (one BUY, one SELL). Reverts with descriptive errors on mismatch.
    /// @param a The first order.
    /// @param b The second order.
    function _validatePairCompatibility(Order calldata a, Order calldata b) internal pure {
        if (a.asset != b.asset || a.epochId != b.epochId) revert InvalidOrder();
        if (a.side == b.side) revert InvalidOrder();
        if (a.outcome != b.outcome) revert MismatchedOutcomes();
    }

    /// @notice Checks whether two opposing orders cross (can be matched).
    /// @dev Orders cross when the buyer's limit price is >= the seller's limit price,
    /// meaning the buyer is willing to pay at least as much as the seller demands.
    /// @param a The first order.
    /// @param b The second order.
    /// @return True if the orders cross and can be matched.
    function _isCrossing(Order calldata a, Order calldata b) internal pure returns (bool) {
        (Order calldata buy, Order calldata sell) = _asBuySell(a, b);
        return uint256(buy.priceBps) >= uint256(sell.priceBps);
    }

    /// @notice Normalizes an arbitrary order pair into explicit buy/sell references.
    /// @dev Given two orders on opposite sides, returns them as (buy, sell) regardless of input ordering.
    /// @param a The first order.
    /// @param b The second order.
    /// @return buy The order on the BUY side.
    /// @return sell The order on the SELL side.
    function _asBuySell(Order calldata a, Order calldata b)
        internal
        pure
        returns (Order calldata buy, Order calldata sell)
    {
        buy = a.side == Side.BUY ? a : b;
        sell = a.side == Side.SELL ? a : b;
    }

    /// @notice Validates an order's fields, recovers the signer from the EIP-712 signature, and binds hash ownership.
    /// @dev Performs comprehensive validation in this order:
    ///   1. Asset enum range check
    ///   2. Non-zero trader address
    ///   3. Valid outcome and side enum values
    ///   4. Nonce not below minimum valid nonce and not individually cancelled
    ///   5. Order not expired
    ///   6. Price in valid range (1–9999 bps)
    ///   7. Non-zero share count
    ///   8. ECDSA signature recovery matches declared trader
    ///   9. Binds order hash to trader on first use (prevents cancellation hijacking)
    /// @param order The order to validate and hash.
    /// @param signature The EIP-712 signature to verify.
    /// @return digest The EIP-712 typed data hash of the order.
    function _verifyAndHashOrderAny(Order calldata order, bytes calldata signature) internal returns (bytes32 digest) {
        _validateAsset(order.asset);
        if (order.trader == address(0)) revert InvalidAddress();
        if (order.outcome != Outcome.DOWN && order.outcome != Outcome.UP) revert InvalidOrder();
        if (order.side != Side.BUY && order.side != Side.SELL) revert InvalidOrder();
        if (order.nonce < minValidNonce[order.trader]) revert OrderIsCancelled();
        if (cancelledNonces[order.trader][order.nonce]) revert OrderIsCancelled();
        if (order.expiry < block.timestamp) revert OrderExpired();
        if (order.priceBps == 0 || order.priceBps >= PRICE_BPS_DENOMINATOR) revert InvalidPrice();
        if (order.shares == 0) revert InvalidAmount();

        digest = _hashTypedDataV4(_orderStructHash(order));
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != order.trader) revert InvalidSignature();

        address ownerForHash = orderOwner[digest];
        if (ownerForHash == address(0)) {
            orderOwner[digest] = order.trader;
        } else if (ownerForHash != order.trader) {
            revert OrderOwnerMismatch();
        }
    }

    /// @notice Computes the EIP-712 struct hash for an order's fields.
    /// @dev Encodes fields in the exact order declared in `ORDER_TYPEHASH`. Must be kept
    /// in sync with the typehash string and the `Order` struct definition.
    /// @param order The order to hash.
    /// @return The keccak256 hash of the ABI-encoded struct fields prefixed with the typehash.
    function _orderStructHash(Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.trader,
                order.asset,
                order.epochId,
                order.outcome,
                order.side,
                order.priceBps,
                order.shares,
                order.expiry,
                order.nonce,
                order.salt
            )
        );
    }

    /// @notice Loads the latest oracle price snapshot and enforces integrity and freshness constraints.
    /// @dev Validates that:
    ///   1. A price has been pushed (`roundId != 0`)
    ///   2. Price is positive
    ///   3. Timestamp is valid (non-zero, not in the future)
    ///   4. Price is fresh (age <= `maxPriceAge`)
    /// @param asset The asset to read the price for.
    /// @return roundId The oracle round identifier.
    /// @return price The oracle price value.
    /// @return updatedAt The timestamp when the price was observed.
    function _readLatestPrice(Asset asset) internal view returns (uint80 roundId, int192 price, uint256 updatedAt) {
        PriceData memory data = latestPrices[asset];
        if (data.roundId == 0) revert OracleRoundIncomplete();
        if (data.price <= 0) revert OraclePriceInvalid();
        if (data.updatedAt == 0 || data.updatedAt > block.timestamp) revert OracleTimestampInvalid();
        if (block.timestamp - data.updatedAt > maxPriceAge) revert OracleTimestampInvalid();
        return (data.roundId, data.price, data.updatedAt);
    }

    /// @notice Calculates quote notional from shares and a basis-point price.
    /// @dev Formula: `notional = shares * priceBps / 10,000`. No overflow protection beyond
    /// Solidity 0.8's built-in checks, which is sufficient for practical share/price ranges.
    /// @param shares The number of shares.
    /// @param priceBps The price per share in basis points.
    /// @return The notional amount in the same denomination as shares.
    function _notional(uint256 shares, uint16 priceBps) internal pure returns (uint256) {
        return (shares * uint256(priceBps)) / PRICE_BPS_DENOMINATOR;
    }

    /// @notice Returns the minimum of three uint256 values.
    /// @param a First value.
    /// @param b Second value.
    /// @param c Third value.
    /// @return The smallest of the three values.
    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 m = a < b ? a : b;
        return m < c ? m : c;
    }

    /// @notice Validates that an asset enum value is within the declared range.
    /// @dev Reverts with `InvalidAsset()` if the uint8 representation exceeds `Asset.DOT`.
    /// @param asset The asset value to validate.
    function _validateAsset(Asset asset) internal pure {
        if (uint8(asset) > uint8(Asset.DOT)) revert InvalidAsset();
    }

    /// @notice Floors a Unix timestamp to 00:00:00 UTC of its day.
    /// @dev Uses modulo arithmetic with `EPOCH_DURATION` (86,400 seconds) to truncate to day boundary.
    /// @param ts The Unix timestamp to floor.
    /// @return The Unix timestamp of 00:00:00 UTC on the same day.
    function _dayStartUtc(uint256 ts) internal pure returns (uint64) {
        return _toUint64(ts - (ts % EPOCH_DURATION));
    }

    /// @notice Safely casts a uint256 to uint64 with explicit overflow checking.
    /// @dev Reverts with `TimestampOverflow()` if the value exceeds `type(uint64).max`.
    /// @param value The uint256 value to cast.
    /// @return The value as uint64.
    function _toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert TimestampOverflow();
        return uint64(value);
    }

    /// @notice Transfers native currency (ETH) to an address with hard failure on send error.
    /// @dev Uses a low-level `call` with empty calldata. Reverts with `NativeTransferFailed()`
    /// if the transfer fails for any reason (recipient reverts, out of gas, etc.).
    /// @param to The recipient address.
    /// @param amount The amount to transfer in wei.
    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Storage Gap
    // ──────────────────────────────────────────────────────────────────────────────

    /// @dev Reserved storage slots for future upgradeable contract versions.
    /// Prevents storage collisions when new state variables are added in future upgrades.
    /// See: https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[50] private __gap;
}
