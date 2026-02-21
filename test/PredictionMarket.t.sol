// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PredictionMarketUpgradeable} from "../src/PredictionMarketUpgradeable.sol";
import {PredictionMarketUpgradeableV2} from "../src/PredictionMarketUpgradeableV2.sol";

contract PredictionMarketTest is Test {
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant MATCHER_PK = 0xB0B;
    uint256 internal constant USER_PK = 0xCAFE;
    uint256 internal constant TREASURY_PK = 0xD00D;

    address internal ownerAddr;
    address internal matcherAddr;
    address internal userAddr;
    address internal treasuryAddr;

    PredictionMarketUpgradeable internal market;

    function setUp() public {
        ownerAddr = vm.addr(OWNER_PK);
        matcherAddr = vm.addr(MATCHER_PK);
        userAddr = vm.addr(USER_PK);
        treasuryAddr = vm.addr(TREASURY_PK);

        vm.warp(1_710_050_400);

        PredictionMarketUpgradeable impl = new PredictionMarketUpgradeable();
        bytes memory initData = abi.encodeCall(PredictionMarketUpgradeable.initialize, (ownerAddr, matcherAddr));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        market = PredictionMarketUpgradeable(payable(address(proxy)));

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
        vm.expectRevert(PredictionMarketUpgradeable.UnauthorizedTreasury.selector);
        market.mint(PredictionMarketUpgradeable.Asset.BTC, 1, 1 ether);

        vm.prank(userAddr);
        vm.expectRevert(PredictionMarketUpgradeable.UnauthorizedTreasury.selector);
        market.merge(PredictionMarketUpgradeable.Asset.BTC, 1, 1 ether);

        vm.prank(treasuryAddr);
        market.mint(PredictionMarketUpgradeable.Asset.BTC, 1, 1 ether);

        vm.prank(ownerAddr);
        market.merge(PredictionMarketUpgradeable.Asset.BTC, 1, 1 ether);

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.pushPrice(PredictionMarketUpgradeable.Asset.BTC, 2, int192(101_000e8), block.timestamp);

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.rollDaily(PredictionMarketUpgradeable.Asset.BTC);

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.resolveEpoch(PredictionMarketUpgradeable.Asset.BTC, 1);

        PredictionMarketUpgradeableV2 implV2 = new PredictionMarketUpgradeableV2();

        vm.prank(userAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userAddr));
        market.upgradeToAndCall(address(implV2), bytes(""));
    }

    function testOrderbookMatchFlowWithTreasuryAsSeller() public {
        _bootstrapAndMintTreasury(3 ether);

        vm.prank(userAddr);
        market.depositCollateral{value: 5 ether}();

        PredictionMarketUpgradeable.Order memory userBuy = PredictionMarketUpgradeable.Order({
            trader: userAddr,
            asset: PredictionMarketUpgradeable.Asset.BTC,
            epochId: 1,
            outcome: PredictionMarketUpgradeable.Outcome.UP,
            side: PredictionMarketUpgradeable.Side.BUY,
            priceBps: 5000,
            shares: 1 ether,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 1,
            salt: bytes32(uint256(111))
        });

        PredictionMarketUpgradeable.Order memory treasurySell = PredictionMarketUpgradeable.Order({
            trader: treasuryAddr,
            asset: PredictionMarketUpgradeable.Asset.BTC,
            epochId: 1,
            outcome: PredictionMarketUpgradeable.Outcome.UP,
            side: PredictionMarketUpgradeable.Side.SELL,
            priceBps: 5000,
            shares: 1 ether,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 2,
            salt: bytes32(uint256(222))
        });

        PredictionMarketUpgradeable.SignedOrder memory taker = PredictionMarketUpgradeable.SignedOrder({
            order: userBuy,
            signature: _signOrder(USER_PK, userBuy)
        });

        PredictionMarketUpgradeable.SignedOrder[] memory makers = new PredictionMarketUpgradeable.SignedOrder[](1);
        makers[0] = PredictionMarketUpgradeable.SignedOrder({
            order: treasurySell,
            signature: _signOrder(TREASURY_PK, treasurySell)
        });

        uint128[] memory makerFills = new uint128[](1);
        makerFills[0] = uint128(1 ether);

        vm.prank(matcherAddr);
        market.matchOrdersPolymarketStyle(taker, makers, uint128(1 ether), makerFills);

        uint256 notional = (1 ether * 5000) / market.PRICE_BPS_DENOMINATOR();

        assertEq(market.freeCollateral(userAddr), 5 ether - notional);
        assertEq(market.freeCollateral(treasuryAddr), 7 ether + notional);
        assertEq(
            market.outcomeShares(treasuryAddr, PredictionMarketUpgradeable.Asset.BTC, 1, PredictionMarketUpgradeable.Outcome.UP),
            2 ether
        );
        assertEq(
            market.outcomeShares(userAddr, PredictionMarketUpgradeable.Asset.BTC, 1, PredictionMarketUpgradeable.Outcome.UP),
            1 ether
        );
    }

    function testResolveAndClaimPaysOneToOne() public {
        _bootstrapAndMintTreasury(3 ether);

        vm.prank(userAddr);
        market.depositCollateral{value: 5 ether}();

        PredictionMarketUpgradeable.Order memory userBuy = PredictionMarketUpgradeable.Order({
            trader: userAddr,
            asset: PredictionMarketUpgradeable.Asset.BTC,
            epochId: 1,
            outcome: PredictionMarketUpgradeable.Outcome.UP,
            side: PredictionMarketUpgradeable.Side.BUY,
            priceBps: 5000,
            shares: 1 ether,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 10,
            salt: bytes32(uint256(333))
        });

        PredictionMarketUpgradeable.Order memory treasurySell = PredictionMarketUpgradeable.Order({
            trader: treasuryAddr,
            asset: PredictionMarketUpgradeable.Asset.BTC,
            epochId: 1,
            outcome: PredictionMarketUpgradeable.Outcome.UP,
            side: PredictionMarketUpgradeable.Side.SELL,
            priceBps: 5000,
            shares: 1 ether,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 20,
            salt: bytes32(uint256(444))
        });

        PredictionMarketUpgradeable.SignedOrder memory taker = PredictionMarketUpgradeable.SignedOrder({
            order: userBuy,
            signature: _signOrder(USER_PK, userBuy)
        });

        PredictionMarketUpgradeable.SignedOrder[] memory makers = new PredictionMarketUpgradeable.SignedOrder[](1);
        makers[0] = PredictionMarketUpgradeable.SignedOrder({
            order: treasurySell,
            signature: _signOrder(TREASURY_PK, treasurySell)
        });

        uint128[] memory makerFills = new uint128[](1);
        makerFills[0] = uint128(1 ether);

        vm.prank(matcherAddr);
        market.matchOrdersPolymarketStyle(taker, makers, uint128(1 ether), makerFills);

        PredictionMarketUpgradeable.Epoch memory epoch = market.getEpoch(PredictionMarketUpgradeable.Asset.BTC, 1);
        vm.warp(epoch.endTs + 1);

        vm.startPrank(ownerAddr);
        market.pushPrice(PredictionMarketUpgradeable.Asset.BTC, 2, int192(101_000e8), block.timestamp);
        market.resolveEpoch(PredictionMarketUpgradeable.Asset.BTC, 1);
        vm.stopPrank();

        uint256 before = userAddr.balance;

        vm.prank(userAddr);
        market.claim(PredictionMarketUpgradeable.Asset.BTC, 1);

        assertEq(userAddr.balance, before + 1 ether);
    }

    function testUpgradeToV2KeepsStorageAndBalances() public {
        _bootstrapAndMintTreasury(2 ether);

        vm.prank(userAddr);
        market.depositCollateral{value: 3 ether}();

        vm.prank(ownerAddr);
        market.setMatcher(address(0xCAFE));

        vm.prank(ownerAddr);
        market.setMaxPriceAge(3 days);

        uint256 treasuryFreeCollateralBefore = market.freeCollateral(treasuryAddr);
        uint256 treasuryUpBefore =
            market.outcomeShares(treasuryAddr, PredictionMarketUpgradeable.Asset.BTC, 1, PredictionMarketUpgradeable.Outcome.UP);

        PredictionMarketUpgradeableV2 implV2 = new PredictionMarketUpgradeableV2();

        vm.prank(ownerAddr);
        market.upgradeToAndCall(address(implV2), bytes(""));

        PredictionMarketUpgradeableV2 upgraded = PredictionMarketUpgradeableV2(payable(address(market)));

        assertEq(upgraded.version(), "v2");
        assertEq(upgraded.owner(), ownerAddr);
        assertEq(upgraded.matcherAddress(), address(0xCAFE));
        assertEq(upgraded.treasury(), treasuryAddr);
        assertEq(upgraded.maxPriceAge(), 3 days);
        assertEq(upgraded.freeCollateral(treasuryAddr), treasuryFreeCollateralBefore);
        assertEq(
            upgraded.outcomeShares(treasuryAddr, PredictionMarketUpgradeable.Asset.BTC, 1, PredictionMarketUpgradeable.Outcome.UP),
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
        market.mint(PredictionMarketUpgradeable.Asset.BTC, 1, amount);
    }

    function _pushInitialPrices() internal {
        vm.startPrank(ownerAddr);
        market.pushPrice(PredictionMarketUpgradeable.Asset.BTC, 1, int192(100_000e8), block.timestamp);
        market.pushPrice(PredictionMarketUpgradeable.Asset.ETH, 1, int192(5_000e8), block.timestamp);
        market.pushPrice(PredictionMarketUpgradeable.Asset.DOT, 1, int192(20e8), block.timestamp);
        vm.stopPrank();
    }

    function _signOrder(uint256 privateKey, PredictionMarketUpgradeable.Order memory order)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = market.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
