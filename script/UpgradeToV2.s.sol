// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {PredictionMarketUpgradeable} from "../src/PredictionMarketUpgradeable.sol";
import {PredictionMarketUpgradeableV2} from "../src/PredictionMarketUpgradeableV2.sol";

contract UpgradeToV2 is Script {
    function run() external returns (address newImplementation) {
        string memory pkRaw = vm.envString("PRIVATE_KEY");
        uint256 privateKey = vm.parseUint(string.concat("0x", pkRaw));
        address proxy = vm.envAddress("PROXY");

        vm.startBroadcast(privateKey);

        PredictionMarketUpgradeableV2 newImplV2 = new PredictionMarketUpgradeableV2();

        PredictionMarketUpgradeable(payable(proxy)).upgradeToAndCall(address(newImplV2), bytes(""));

        string memory v = PredictionMarketUpgradeableV2(payable(proxy)).version();
        require(keccak256(bytes(v)) == keccak256(bytes("v2")), "upgrade failed");

        vm.stopBroadcast();

        newImplementation = address(newImplV2);

        console2.log("newImplementation:", newImplementation);
        console2.log("version:", v);
    }
}
