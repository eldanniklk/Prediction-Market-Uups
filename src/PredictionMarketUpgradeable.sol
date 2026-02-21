// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract PredictionMarketUpgradeable is
    Initializable,
    OwnableUpgradeable,
    EIP712Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant EPOCH_DURATION = 1 days;
    uint256 public constant PRICE_BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_MAX_PRICE_AGE = 2 days;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,uint8 asset,uint256 epochId,uint8 outcome,uint8 side,uint16 priceBps,uint128 shares,uint64 expiry,uint64 nonce,bytes32 salt)"
    );

    enum Asset {
        BTC,
        ETH,
        DOT
    }

    enum Outcome {
        DOWN,
        UP
    }

    enum Side {
        BUY,
        SELL
    }

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

    struct SignedOrder {
        Order order;
        bytes signature;
    }

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

    struct PriceData {
        uint80 roundId;
        int192 price;
        uint256 updatedAt;
    }

    error InvalidAddress();
    error InvalidAmount();
    error InvalidAsset();
    error InvalidOrder();
    error InvalidSignature();
    error InvalidPrice();
    error InvalidEpoch();
    error EpochEnded();
    error EpochNotEnded();
    error EpochAlreadyResolved();
    error EpochNotResolved();
    error EpochActive();
    error InsufficientCollateral();
    error InsufficientShares();
    error OrderExpired();
    error OrderIsCancelled();
    error OrderOverfilled();
    error OracleRoundIncomplete();
    error OraclePriceInvalid();
    error OracleTimestampInvalid();
    error NothingToClaim();
    error OrderOwnerMismatch();
    error FillArrayLengthMismatch();
    error NotCrossing();
    error MismatchedOutcomes();
    error UnauthorizedMatcher();
    error TimestampOverflow();
    error NativeTransferFailed();
    error MarketsAlreadyBootstrapped();
    error MarketsNotBootstrapped();
    error InvalidNonce();
    error PriceNotInCurrentUtcDay();
    error UnauthorizedTreasury();

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Minted(address indexed user, Asset indexed asset, uint256 indexed epochId, uint256 amount);
    event Merged(address indexed user, Asset indexed asset, uint256 indexed epochId, uint256 shares);
    event Claimed(address indexed user, Asset indexed asset, uint256 indexed epochId, Outcome winner, uint256 payout);
    event OrderCancelled(bytes32 indexed orderHash, address indexed trader);
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
    event PriceUpdated(Asset indexed asset, uint80 roundId, int192 price, uint256 updatedAt);
    event EpochCreated(Asset indexed asset, uint256 indexed epochId, uint64 startTs, uint64 endTs, int192 startPrice, uint80 roundId);
    event EpochResolved(Asset indexed asset, uint256 indexed epochId, Outcome winningOutcome, int192 finalPrice, uint80 roundId);
    event MatcherUpdated(address indexed matcher);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event MarketsBootstrapped(uint64 indexed dayStartTs);
    event NonceCancelled(address indexed trader, uint64 nonce);
    event MinValidNonceUpdated(address indexed trader, uint64 minValidNonce);
    event TreasuryUpdated(address indexed treasury);

    address public matcherAddress;
    address public treasury;
    uint256 public maxPriceAge;
    bool public marketsBootstrapped;

    mapping(Asset => PriceData) public latestPrices;
    mapping(Asset => uint256) public latestEpochId;
    mapping(Asset => mapping(uint256 => Epoch)) public epochs;
    mapping(Asset => mapping(uint256 => uint256)) public epochEscrow;

    mapping(address => uint256) public freeCollateral;
    mapping(address => mapping(Asset => mapping(uint256 => mapping(Outcome => uint256)))) public outcomeShares;

    mapping(bytes32 => uint256) public filledShares;
    mapping(bytes32 => bool) public cancelledOrders;
    mapping(bytes32 => address) public orderOwner;
    mapping(address => mapping(uint64 => bool)) public cancelledNonces;
    mapping(address => uint64) public minValidNonce;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address initialMatcher) external initializer {
        if (initialOwner == address(0) || initialMatcher == address(0)) revert InvalidAddress();

        __Ownable_init(initialOwner);
        __EIP712_init("PredictionMarket", "1");
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        matcherAddress = initialMatcher;
        treasury = initialOwner;
        maxPriceAge = DEFAULT_MAX_PRICE_AGE;
    }

    modifier onlyMatcherOrOwner() {
        if (msg.sender != owner() && msg.sender != matcherAddress) revert UnauthorizedMatcher();
        _;
    }

    modifier onlyOwnerOrTreasury() {
        if (msg.sender != owner() && msg.sender != treasury) revert UnauthorizedTreasury();
        _;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setMatcher(address newMatcher) external onlyOwner {
        if (newMatcher == address(0)) revert InvalidAddress();
        matcherAddress = newMatcher;
        emit MatcherUpdated(newMatcher);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setMaxPriceAge(uint256 newMaxPriceAge) external onlyOwner {
        if (newMaxPriceAge == 0) revert InvalidAmount();
        maxPriceAge = newMaxPriceAge;
        emit MaxPriceAgeUpdated(newMaxPriceAge);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

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

    function rollDaily(Asset asset) external onlyOwner {
        _rollDaily(asset);
    }

    function rollDailyAll() external onlyOwner {
        _rollDaily(Asset.BTC);
        _rollDaily(Asset.ETH);
        _rollDaily(Asset.DOT);
    }

    function resolveEpoch(Asset asset, uint256 epochId) external onlyOwner {
        _validateAsset(asset);
        Epoch storage epoch = epochs[asset][epochId];
        if (epoch.endTs == 0) revert InvalidEpoch();
        _resolveEpoch(asset, epochId, epoch);
    }

    function depositCollateral() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert InvalidAmount();
        freeCollateral[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (freeCollateral[msg.sender] < amount) revert InsufficientCollateral();

        freeCollateral[msg.sender] -= amount;
        _sendNative(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function mint(Asset asset, uint256 epochId, uint256 amount) external onlyOwnerOrTreasury nonReentrant whenNotPaused {
        _mint(asset, epochId, amount);
    }

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

    function cancelOrder(bytes32 orderHash) external {
        if (orderOwner[orderHash] != msg.sender) revert OrderOwnerMismatch();
        cancelledOrders[orderHash] = true;
        emit OrderCancelled(orderHash, msg.sender);
    }

    function cancelNonce(uint64 nonce) external {
        cancelledNonces[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    function cancelAllUpTo(uint64 newMinValidNonce) external {
        uint64 current = minValidNonce[msg.sender];
        if (newMinValidNonce <= current) revert InvalidNonce();
        minValidNonce[msg.sender] = newMinValidNonce;
        emit MinValidNonceUpdated(msg.sender, newMinValidNonce);
    }

    function cancelOrderBySig(Order calldata order, bytes calldata signature) external {
        if (order.trader != msg.sender) revert OrderOwnerMismatch();
        bytes32 orderHash = _verifyAndHashOrderAny(order, signature);
        cancelledOrders[orderHash] = true;
        emit OrderCancelled(orderHash, msg.sender);
    }

    function hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_orderStructHash(order));
    }

    function previewNotional(uint256 shares, uint16 priceBps) external pure returns (uint256) {
        if (priceBps == 0 || priceBps >= PRICE_BPS_DENOMINATOR) revert InvalidPrice();
        return _notional(shares, priceBps);
    }

    function getCurrentEpoch(Asset asset) external view returns (uint256 epochId, Epoch memory epoch) {
        _validateAsset(asset);
        epochId = latestEpochId[asset];
        epoch = epochs[asset][epochId];
    }

    function getEpoch(Asset asset, uint256 epochId) external view returns (Epoch memory) {
        _validateAsset(asset);
        return epochs[asset][epochId];
    }

    function getUserShares(address user, Asset asset, uint256 epochId) external view returns (uint256 up, uint256 down) {
        _validateAsset(asset);
        up = outcomeShares[user][asset][epochId][Outcome.UP];
        down = outcomeShares[user][asset][epochId][Outcome.DOWN];
    }

    function getFreeCollateral(address user) external view returns (uint256) {
        return freeCollateral[user];
    }

    function getLatestPrice(Asset asset) external view returns (PriceData memory) {
        _validateAsset(asset);
        return latestPrices[asset];
    }

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

    function _validatePairCompatibility(Order calldata a, Order calldata b) internal pure {
        if (a.asset != b.asset || a.epochId != b.epochId) revert InvalidOrder();
        if (a.side == b.side) revert InvalidOrder();
        if (a.outcome != b.outcome) revert MismatchedOutcomes();
    }

    function _isCrossing(Order calldata a, Order calldata b) internal pure returns (bool) {
        (Order calldata buy, Order calldata sell) = _asBuySell(a, b);
        return uint256(buy.priceBps) >= uint256(sell.priceBps);
    }

    function _asBuySell(Order calldata a, Order calldata b)
        internal
        pure
        returns (Order calldata buy, Order calldata sell)
    {
        buy = a.side == Side.BUY ? a : b;
        sell = a.side == Side.SELL ? a : b;
    }

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

    function _readLatestPrice(Asset asset) internal view returns (uint80 roundId, int192 price, uint256 updatedAt) {
        PriceData memory data = latestPrices[asset];
        if (data.roundId == 0) revert OracleRoundIncomplete();
        if (data.price <= 0) revert OraclePriceInvalid();
        if (data.updatedAt == 0 || data.updatedAt > block.timestamp) revert OracleTimestampInvalid();
        if (block.timestamp - data.updatedAt > maxPriceAge) revert OracleTimestampInvalid();
        return (data.roundId, data.price, data.updatedAt);
    }

    function _notional(uint256 shares, uint16 priceBps) internal pure returns (uint256) {
        return (shares * uint256(priceBps)) / PRICE_BPS_DENOMINATOR;
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 m = a < b ? a : b;
        return m < c ? m : c;
    }

    function _validateAsset(Asset asset) internal pure {
        if (uint8(asset) > uint8(Asset.DOT)) revert InvalidAsset();
    }

    function _dayStartUtc(uint256 ts) internal pure returns (uint64) {
        return _toUint64(ts - (ts % EPOCH_DURATION));
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert TimestampOverflow();
        return uint64(value);
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    uint256[50] private __gap;
}
