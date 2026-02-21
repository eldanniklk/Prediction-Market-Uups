// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PredictionMarketUpgradeable} from "../src/PredictionMarketUpgradeable.sol";

contract DeployProxy is Script {
    function run() external returns (address implementation, address proxyAddress) {
        string memory rpcUrl = vm.envString("RPC_URL");
        rpcUrl;

        string memory pkRaw = vm.envString("PRIVATE_KEY");
        uint256 privateKey = vm.parseUint(string.concat("0x", pkRaw));
        address owner = vm.envAddress("OWNER");
        address matcher = vm.envAddress("MATCHER");

        vm.startBroadcast(privateKey);

        PredictionMarketUpgradeable impl = new PredictionMarketUpgradeable();
        bytes memory initData = abi.encodeCall(PredictionMarketUpgradeable.initialize, (owner, matcher));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        vm.stopBroadcast();

        implementation = address(impl);
        proxyAddress = address(proxy);

        console2.log("implementation:", implementation);
        console2.log("proxy:", proxyAddress);
        console2.log("owner:", owner);
        console2.log("matcher:", matcher);
    }
}
