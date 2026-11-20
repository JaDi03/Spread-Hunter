// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SpreadHunterReactive} from "../../src/reactive/SpreadHunterReactive.sol";
import {Testnet} from "./Testnet.sol";

/// @title DemoPair
/// @notice The USDC/HUNT pair the testnet demo trades: its pools, trading parameters, inventory and funding.
/// Side 0 is Base Sepolia and side 1 is Unichain Sepolia.
library DemoPair {
    address internal constant BASE_SEPOLIA_HUNT = 0xDf9a8390085267F6E197Bd4D28d4532c19628391;
    address internal constant UNICHAIN_SEPOLIA_HUNT = 0xFF548c03b910bF69eeb026B10CF195a9925F9719;

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant POOL_TICK_SPACING = 10;

    uint256 internal constant INVENTORY_USDC = 100e6;
    uint256 internal constant INVENTORY_TOKEN = 10_000e18;
    uint256 internal constant REACTIVE_FUNDING = 5 ether;
    uint256 internal constant EXECUTOR_FUNDING = 0.005 ether;

    function token(uint256 chainId) internal pure returns (address) {
        if (chainId == Testnet.BASE_SEPOLIA) return BASE_SEPOLIA_HUNT;
        if (chainId == Testnet.UNICHAIN_SEPOLIA) return UNICHAIN_SEPOLIA_HUNT;
        revert Testnet.UnknownChain(chainId);
    }

    function params() internal pure returns (SpreadHunterReactive.Params memory) {
        return SpreadHunterReactive.Params({
            minProfitUsdc: 0.01e6, maxTradeUsdc: 50e6, slippageBps: 50, legTimeout: 60, callbackGas: 400_000
        });
    }
}
