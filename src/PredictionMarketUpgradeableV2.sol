// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PredictionMarketUpgradeable} from "./PredictionMarketUpgradeable.sol";

contract PredictionMarketUpgradeableV2 is PredictionMarketUpgradeable {
    function version() external pure returns (string memory) {
        return "v2";
    }
}
