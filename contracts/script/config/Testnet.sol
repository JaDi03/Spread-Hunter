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

    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant UNICHAIN_SEPOLIA_USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    /// @notice Circle USDC on `chainId`.
    function usdc(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_SEPOLIA) return BASE_SEPOLIA_USDC;
        if (chainId == UNICHAIN_SEPOLIA) return UNICHAIN_SEPOLIA_USDC;
        revert UnknownChain(chainId);
    }

    /// @notice Uniswap V4 PoolManager on `chainId`.
    function poolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_SEPOLIA) return BASE_SEPOLIA_POOL_MANAGER;
        if (chainId == UNICHAIN_SEPOLIA) return UNICHAIN_SEPOLIA_POOL_MANAGER;
        revert UnknownChain(chainId);
    }

    /// @notice Callback proxy that delivers Reactive callbacks on `chainId`.
    function callbackProxy(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_SEPOLIA) return BASE_SEPOLIA_CALLBACK_PROXY;
        if (chainId == UNICHAIN_SEPOLIA) return UNICHAIN_SEPOLIA_CALLBACK_PROXY;
        revert UnknownChain(chainId);
    }
}
