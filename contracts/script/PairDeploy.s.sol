// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Executor} from "../src/executor/Executor.sol";
import {SpreadHunterReactive} from "../src/reactive/SpreadHunterReactive.sol";
import {DemoPair} from "./config/DemoPair.sol";
import {Testnet} from "./config/Testnet.sol";

/// @title PairDeploy
/// @notice Deploys SpreadHunter for the demo pair, one step per call, each against its own RPC.
/// Order: reactive (Lasna) -> executor (Base Sepolia) -> executor (Unichain Sepolia) -> link (Lasna)
/// -> fund (each chain). The Executors need the reactive contract's address at deploy, so it goes first.
/// Pool, USDC and PoolManager always come from the network config, never from arguments.
contract PairDeploy is Script {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    error WrongChain(uint256 actual);
    error PoolMismatch(bytes32 expected, bytes32 actual);
    error NotOwner(address owner);

    function reactive() external returns (SpreadHunterReactive deployed) {
        if (block.chainid != Testnet.LASNA) revert WrongChain(block.chainid);
        vm.startBroadcast();
        deployed = new SpreadHunterReactive{value: DemoPair.REACTIVE_FUNDING}(
            _pool(Testnet.BASE_SEPOLIA), _pool(Testnet.UNICHAIN_SEPOLIA), DemoPair.params()
        );
        vm.stopBroadcast();
        console.log("REACTIVE=%s", address(deployed));
    }

    /// @param rc The reactive contract on Lasna, the only sender whose callbacks the Executor accepts.
    function executor(address rc) external returns (Executor deployed) {
        PoolKey memory key = poolKey(block.chainid);
        vm.startBroadcast();
        // the owner is the account that broadcasts this step
        deployed = new Executor{value: DemoPair.EXECUTOR_FUNDING}(
            IPayable(payable(Testnet.callbackProxy(block.chainid))),
            rc,
            IPoolManager(Testnet.poolManager(block.chainid)),
            key,
            Testnet.usdc(block.chainid),
            tx.origin
        );
        vm.stopBroadcast();
        console.log("EXECUTOR=%s", address(deployed));
    }

    /// @param rc The reactive contract on Lasna.
    /// @param baseExecutor Executor on Base Sepolia.
    /// @param unichainExecutor Executor on Unichain Sepolia.
    function link(address rc, address baseExecutor, address unichainExecutor) external {
        if (block.chainid != Testnet.LASNA) revert WrongChain(block.chainid);
        vm.startBroadcast();
        SpreadHunterReactive(payable(rc)).link(baseExecutor, unichainExecutor);
        vm.stopBroadcast();
    }

    /// @notice Moves the demo inventory into the Executor and reports it to the reactive contract.
    function fund(address executor_) external {
        Executor ex = Executor(payable(executor_));
        if (ex.owner() != tx.origin) revert NotOwner(ex.owner());
        bytes32 expected = PoolId.unwrap(poolKey(block.chainid).toId());
        if (PoolId.unwrap(ex.poolId()) != expected) revert PoolMismatch(expected, PoolId.unwrap(ex.poolId()));
        vm.startBroadcast();
        IERC20(Testnet.usdc(block.chainid)).safeTransfer(executor_, DemoPair.INVENTORY_USDC);
        IERC20(DemoPair.token(block.chainid)).safeTransfer(executor_, DemoPair.INVENTORY_TOKEN);
        ex.sync();
        vm.stopBroadcast();
    }

    /// @notice The demo pool on `chainId`, with its currencies in Uniswap's order.
    function poolKey(uint256 chainId) public pure returns (PoolKey memory) {
        address usdc = Testnet.usdc(chainId);
        address token = DemoPair.token(chainId);
        (address c0, address c1) = usdc < token ? (usdc, token) : (token, usdc);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: DemoPair.POOL_FEE,
            tickSpacing: DemoPair.POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _pool(uint256 chainId) internal pure returns (SpreadHunterReactive.Pool memory) {
        PoolKey memory key = poolKey(chainId);
        return SpreadHunterReactive.Pool({
            chainId: chainId,
            poolManager: Testnet.poolManager(chainId),
            poolId: PoolId.unwrap(key.toId()),
            usdcIsCurrency0: Currency.unwrap(key.currency0) == Testnet.usdc(chainId),
            fee: DemoPair.POOL_FEE
        });
    }
}
