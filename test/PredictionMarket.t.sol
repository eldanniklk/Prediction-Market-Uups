// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PredictionMarket} from "../src/PredictionMarket.sol";

contract PredictionMarketTest is Test {
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant MATCHER_PK = 0xB0B;
    uint256 internal constant USER_PK = 0xCAFE;
    uint256 internal constant TREASURY_PK = 0xD00D;

    address internal ownerAddr;
    address internal matcherAddr;
    address internal userAddr;
    address internal treasuryAddr;

    PredictionMarket internal market;

    function setUp() public {
        ownerAddr = vm.addr(OWNER_PK);
        matcherAddr = vm.addr(MATCHER_PK);
        userAddr = vm.addr(USER_PK);
        treasuryAddr = vm.addr(TREASURY_PK);

        vm.warp(1_710_050_400);

        PredictionMarket impl = new PredictionMarket();
        bytes memory initData = abi.encodeCall(PredictionMarket.initialize, (ownerAddr, matcherAddr));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        market = PredictionMarket(payable(address(proxy)));

        vm.deal(ownerAddr, 200 ether);
        vm.deal(userAddr, 200 ether);
        vm.deal(treasuryAddr, 200 ether);
    }

    function testInitializeOnlyOnce() public {
        vm.expectRevert();
        market.initialize(ownerAddr, matcherAddr);
    }

    function testPermissions() public {
        _pushInitialPrices();

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.bootstrapDailyEpochs();

        vm.prank(ownerAddr);
        market.bootstrapDailyEpochs();

        vm.prank(ownerAddr);
        market.setTreasury(treasuryAddr);

        vm.prank(treasuryAddr);
        market.depositCollateral{value: 3 ether}();

        vm.prank(userAddr);
        vm.expectRevert(PredictionMarket.UnauthorizedTreasury.selector);
        market.mint(PredictionMarket.Asset.BTC, 1, 1 ether);

        vm.prank(userAddr);
        vm.expectRevert(PredictionMarket.UnauthorizedTreasury.selector);
        market.merge(PredictionMarket.Asset.BTC, 1, 1 ether);

        vm.prank(treasuryAddr);
        market.mint(PredictionMarket.Asset.BTC, 1, 1 ether);

        vm.prank(ownerAddr);
        market.merge(PredictionMarket.Asset.BTC, 1, 1 ether);

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.pushPrice(PredictionMarket.Asset.BTC, 2, int192(101_000e8), block.timestamp);

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.rollDaily(PredictionMarket.Asset.BTC);

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.resolveEpoch(PredictionMarket.Asset.BTC, 1);

        PredictionMarketUpgradeMock upgradedImpl = new PredictionMarketUpgradeMock();

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.upgradeToAndCall(address(upgradedImpl), bytes(""));
    }

    function testOrderbookMatchFlowWithTreasuryAsSeller() public {
        _bootstrapAndMintTreasury(3 ether);

        vm.prank(userAddr);
        market.depositCollateral{value: 5 ether}();

        PredictionMarket.Order memory userBuy = PredictionMarket.Order({
            trader: userAddr,
            asset: PredictionMarket.Asset.BTC,
            epochId: 1,
            outcome: PredictionMarket.Outcome.UP,
            side: PredictionMarket.Side.BUY,
            priceBps: 5000,
            shares: 1 ether,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 1,
            salt: bytes32(uint256(111))
        });

        PredictionMarket.Order memory treasurySell = PredictionMarket.Order({
            trader: treasuryAddr,
            asset: PredictionMarket.Asset.BTC,
            epochId: 1,
            outcome: PredictionMarket.Outcome.UP,
            side: PredictionMarket.Side.SELL,
            priceBps: 5000,
            shares: 1 ether,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 2,
            salt: bytes32(uint256(222))
        });

        PredictionMarket.SignedOrder memory taker =
            PredictionMarket.SignedOrder({order: userBuy, signature: _signOrder(USER_PK, userBuy)});

        PredictionMarket.SignedOrder[] memory makers = new PredictionMarket.SignedOrder[](1);
        makers[0] =
            PredictionMarket.SignedOrder({order: treasurySell, signature: _signOrder(TREASURY_PK, treasurySell)});

        uint128[] memory makerFills = new uint128[](1);
        makerFills[0] = uint128(1 ether);

        vm.prank(matcherAddr);
        market.matchOrdersPolymarketStyle(taker, makers, uint128(1 ether), makerFills);

        uint256 notional = (1 ether * 5000) / market.PRICE_BPS_DENOMINATOR();

        assertEq(market.freeCollateral(userAddr), 5 ether - notional);
        assertEq(market.freeCollateral(treasuryAddr), 7 ether + notional);
        assertEq(
            market.outcomeShares(treasuryAddr, PredictionMarket.Asset.BTC, 1, PredictionMarket.Outcome.UP), 2 ether
        );
        assertEq(market.outcomeShares(userAddr, PredictionMarket.Asset.BTC, 1, PredictionMarket.Outcome.UP), 1 ether);
    }

    function testResolveAndClaimPaysOneToOne() public {
        _bootstrapAndMintTreasury(3 ether);

        vm.prank(userAddr);
        market.depositCollateral{value: 5 ether}();

        PredictionMarket.Order memory userBuy = PredictionMarket.Order({
            trader: userAddr,
            asset: PredictionMarket.Asset.BTC,
            epochId: 1,
            outcome: PredictionMarket.Outcome.UP,
            side: PredictionMarket.Side.BUY,
            priceBps: 5000,
            shares: 1 ether,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 10,
            salt: bytes32(uint256(333))
        });

        PredictionMarket.Order memory treasurySell = PredictionMarket.Order({
            trader: treasuryAddr,
            asset: PredictionMarket.Asset.BTC,
            epochId: 1,
            outcome: PredictionMarket.Outcome.UP,
            side: PredictionMarket.Side.SELL,
            priceBps: 5000,
            shares: 1 ether,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 20,
            salt: bytes32(uint256(444))
        });

        PredictionMarket.SignedOrder memory taker =
            PredictionMarket.SignedOrder({order: userBuy, signature: _signOrder(USER_PK, userBuy)});

        PredictionMarket.SignedOrder[] memory makers = new PredictionMarket.SignedOrder[](1);
        makers[0] =
            PredictionMarket.SignedOrder({order: treasurySell, signature: _signOrder(TREASURY_PK, treasurySell)});

        uint128[] memory makerFills = new uint128[](1);
        makerFills[0] = uint128(1 ether);

        vm.prank(matcherAddr);
        market.matchOrdersPolymarketStyle(taker, makers, uint128(1 ether), makerFills);

        PredictionMarket.Epoch memory epoch = market.getEpoch(PredictionMarket.Asset.BTC, 1);
        vm.warp(epoch.endTs + 1);

        vm.startPrank(ownerAddr);
        market.pushPrice(PredictionMarket.Asset.BTC, 2, int192(101_000e8), block.timestamp);
        market.resolveEpoch(PredictionMarket.Asset.BTC, 1);
        vm.stopPrank();

        uint256 before = userAddr.balance;

        vm.prank(userAddr);
        market.claim(PredictionMarket.Asset.BTC, 1);

        assertEq(userAddr.balance, before + 1 ether);
    }

    function testUpgradeKeepsStorageAndBalances() public {
        _bootstrapAndMintTreasury(2 ether);

        vm.prank(userAddr);
        market.depositCollateral{value: 3 ether}();

        vm.prank(ownerAddr);
        market.setMatcher(address(0xCAFE));

        vm.prank(ownerAddr);
        market.setMaxPriceAge(3 days);

        uint256 treasuryFreeCollateralBefore = market.freeCollateral(treasuryAddr);
        uint256 treasuryUpBefore =
            market.outcomeShares(treasuryAddr, PredictionMarket.Asset.BTC, 1, PredictionMarket.Outcome.UP);

        PredictionMarketUpgradeMock upgradedImpl = new PredictionMarketUpgradeMock();

        vm.prank(ownerAddr);
        market.upgradeToAndCall(address(upgradedImpl), bytes(""));

        PredictionMarketUpgradeMock upgraded = PredictionMarketUpgradeMock(payable(address(market)));

        assertEq(upgraded.version(), "upgraded");
        assertEq(upgraded.owner(), ownerAddr);
        assertEq(upgraded.matcherAddress(), address(0xCAFE));
        assertEq(upgraded.treasury(), treasuryAddr);
        assertEq(upgraded.maxPriceAge(), 3 days);
        assertEq(upgraded.freeCollateral(treasuryAddr), treasuryFreeCollateralBefore);
        assertEq(
            upgraded.outcomeShares(treasuryAddr, PredictionMarket.Asset.BTC, 1, PredictionMarket.Outcome.UP),
            treasuryUpBefore
        );
    }

    function _bootstrapAndMintTreasury(uint256 amount) internal {
        _pushInitialPrices();

        vm.prank(ownerAddr);
        market.bootstrapDailyEpochs();

        vm.prank(ownerAddr);
        market.setTreasury(treasuryAddr);

        vm.prank(treasuryAddr);
        market.depositCollateral{value: 10 ether}();

        vm.prank(treasuryAddr);
        market.mint(PredictionMarket.Asset.BTC, 1, amount);
    }

    function _pushInitialPrices() internal {
        vm.startPrank(ownerAddr);
        market.pushPrice(PredictionMarket.Asset.BTC, 1, int192(100_000e8), block.timestamp);
        market.pushPrice(PredictionMarket.Asset.ETH, 1, int192(5_000e8), block.timestamp);
        market.pushPrice(PredictionMarket.Asset.DOT, 1, int192(20e8), block.timestamp);
        vm.stopPrank();
    }

    function _signOrder(uint256 privateKey, PredictionMarket.Order memory order) internal view returns (bytes memory) {
        bytes32 digest = market.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract PredictionMarketUpgradeMock is PredictionMarket {
    function version() external pure returns (string memory) {
        return "upgraded";
    }
}
