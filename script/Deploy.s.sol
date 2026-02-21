// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PredictionMarketUpgradeable} from "../src/PredictionMarketUpgradeable.sol";

contract DeployScript is Script {
    function run() external returns (address proxyAddr, address implementationAddr) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address initialOwner = vm.envAddress("OWNER_ADDRESS");
        address initialMatcher = vm.envAddress("MATCHER_ADDRESS");
        address treasuryAddr = vm.envOr("TREASURY_ADDRESS", initialOwner);

        vm.startBroadcast(deployerPk);

        PredictionMarketUpgradeable implementation = new PredictionMarketUpgradeable();
        bytes memory initData = abi.encodeCall(PredictionMarketUpgradeable.initialize, (initialOwner, initialMatcher));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        PredictionMarketUpgradeable market = PredictionMarketUpgradeable(payable(address(proxy)));

        if (treasuryAddr != initialOwner) {
            market.setTreasury(treasuryAddr);
        }

        vm.stopBroadcast();

        proxyAddr = address(proxy);
        implementationAddr = address(implementation);

        console2.log("Proxy:", proxyAddr);
        console2.log("Implementation:", implementationAddr);
        console2.log("Owner:", market.owner());
        console2.log("Matcher:", market.matcherAddress());
        console2.log("Treasury:", market.treasury());

        string memory chainId = vm.toString(block.chainid);
        string memory obj = "deployment";
        vm.serializeAddress(obj, "proxy", proxyAddr);
        vm.serializeAddress(obj, "implementation", implementationAddr);
        vm.serializeAddress(obj, "owner", market.owner());
        vm.serializeAddress(obj, "matcher", market.matcherAddress());
        string memory json = vm.serializeAddress(obj, "treasury", market.treasury());
        string memory outPath = string.concat(vm.projectRoot(), "/deployments/", chainId, ".json");
        vm.writeJson(json, outPath);
    }
}
