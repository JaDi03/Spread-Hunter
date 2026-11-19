// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Testnet
/// @notice Chain ids and Reactive callback proxies for the testnet deployment, the single source for scripts.
library Testnet {
    error UnknownChain(uint256 chainId);

    uint256 internal constant LASNA = 5318007;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;

    address internal constant LASNA_SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address internal constant UNICHAIN_SEPOLIA_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    /// @notice Callback proxy that delivers Reactive callbacks on `chainId`.
    function callbackProxy(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_SEPOLIA) return BASE_SEPOLIA_CALLBACK_PROXY;
        if (chainId == UNICHAIN_SEPOLIA) return UNICHAIN_SEPOLIA_CALLBACK_PROXY;
        revert UnknownChain(chainId);
    }

    /// @notice The other chain of the arbitrage pair: HUNT bridges between these two only.
    function peerChain(uint256 chainId) internal pure returns (uint256) {
        if (chainId == BASE_SEPOLIA) return UNICHAIN_SEPOLIA;
        if (chainId == UNICHAIN_SEPOLIA) return BASE_SEPOLIA;
        revert UnknownChain(chainId);
    }
}
