// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PairDeploy} from "../../script/PairDeploy.s.sol";
import {DemoPair} from "../../script/config/DemoPair.sol";
import {Testnet} from "../../script/config/Testnet.sol";
import {Executor} from "../../src/executor/Executor.sol";
import {SpreadHunterReactive} from "../../src/reactive/SpreadHunterReactive.sol";
import {MockSystem} from "../utils/MockSystem.sol";
import {MockToken} from "../utils/MockToken.sol";

/// Runs the deploy steps against local stand-ins placed at the real testnet addresses.
contract PairDeployTest is Test {
    using PoolIdLibrary for PoolKey;

    /// Demo pool ids read on chain on 2026-11-19 (StateView getSlot0 and getLiquidity).
    bytes32 internal constant BASE_DEMO_POOL = 0xff22002f000707834d52741f48fef85a77aebc7ac17d1ed9a64538b036d711b2;
    bytes32 internal constant UNICHAIN_DEMO_POOL = 0xac8899d8e500a5741a4c146f1d465e76c69daf365a46aa6a95305ea4cfddf9c5;

    PairDeploy internal script;
    address internal deployer;

    function setUp() public {
        // with no key in the script, forge broadcasts from the --sender / --account address, tx.origin in tests
        deployer = tx.origin;
        vm.deal(deployer, 100 ether);
        vm.etch(Testnet.LASNA_SYSTEM, address(new MockSystem()).code);
        vm.etch(Testnet.BASE_SEPOLIA_CALLBACK_PROXY, address(new MockSystem()).code);
        vm.etch(Testnet.UNICHAIN_SEPOLIA_CALLBACK_PROXY, address(new MockSystem()).code);
        script = new PairDeploy();
        _standIns(Testnet.BASE_SEPOLIA);
        _standIns(Testnet.UNICHAIN_SEPOLIA);
    }

    function test_poolKeys_matchTheDemoPoolsOnChain() public view {
        assertEq(PoolId.unwrap(script.poolKey(Testnet.BASE_SEPOLIA).toId()), BASE_DEMO_POOL);
        assertEq(PoolId.unwrap(script.poolKey(Testnet.UNICHAIN_SEPOLIA).toId()), UNICHAIN_DEMO_POOL);
    }

    function test_fullSequence_wiresAndFundsThePair() public {
        vm.chainId(Testnet.LASNA);
        SpreadHunterReactive rc = script.reactive();

        vm.chainId(Testnet.BASE_SEPOLIA);
        Executor base = script.executor(address(rc));
        vm.chainId(Testnet.UNICHAIN_SEPOLIA);
        Executor uni = script.executor(address(rc));

        vm.chainId(Testnet.LASNA);
        script.link(address(rc), address(base), address(uni));

        vm.chainId(Testnet.BASE_SEPOLIA);
        script.fund(address(base));
        vm.chainId(Testnet.UNICHAIN_SEPOLIA);
        script.fund(address(uni));

        assertEq(rc.owner(), deployer);
        assertEq(address(rc).balance, DemoPair.REACTIVE_FUNDING);
        assertEq(rc.pool(0).poolId, BASE_DEMO_POOL);
        assertEq(rc.pool(1).poolId, UNICHAIN_DEMO_POOL);
        assertEq(rc.pool(0).poolManager, Testnet.BASE_SEPOLIA_POOL_MANAGER);
        assertEq(rc.pool(1).poolManager, Testnet.UNICHAIN_SEPOLIA_POOL_MANAGER);
        assertEq(rc.executors(0), address(base));
        assertEq(rc.executors(1), address(uni));
        assertEq(MockSystem(payable(Testnet.LASNA_SYSTEM)).subCount(), 8);

        for (uint256 i; i < 2; ++i) {
            Executor ex = i == 0 ? base : uni;
            uint256 chainId = i == 0 ? Testnet.BASE_SEPOLIA : Testnet.UNICHAIN_SEPOLIA;
            assertEq(ex.owner(), deployer);
            assertEq(ex._CALLBACK_SENDER(), address(rc));
            assertEq(address(ex._SERVICE_PROVIDER()), Testnet.callbackProxy(chainId));
            assertEq(address(ex.poolManager()), Testnet.poolManager(chainId));
            assertEq(Currency.unwrap(ex.usdc()), Testnet.usdc(chainId));
            assertEq(address(ex).balance, DemoPair.EXECUTOR_FUNDING);
            assertEq(MockToken(Testnet.usdc(chainId)).balanceOf(address(ex)), DemoPair.INVENTORY_USDC);
            assertEq(MockToken(DemoPair.token(chainId)).balanceOf(address(ex)), DemoPair.INVENTORY_TOKEN);
        }
    }

    function test_eachStep_rejectsWrongChain() public {
        vm.chainId(Testnet.BASE_SEPOLIA);
        vm.expectRevert(abi.encodeWithSelector(PairDeploy.WrongChain.selector, Testnet.BASE_SEPOLIA));
        script.reactive();
        vm.expectRevert(abi.encodeWithSelector(PairDeploy.WrongChain.selector, Testnet.BASE_SEPOLIA));
        script.link(address(1), address(2), address(3));

        vm.chainId(Testnet.LASNA);
        vm.expectRevert(abi.encodeWithSelector(Testnet.UnknownChain.selector, Testnet.LASNA));
        script.executor(address(1));
    }

    function test_fund_rejectsAnExecutorOfAnotherOwner() public {
        vm.chainId(Testnet.LASNA);
        SpreadHunterReactive rc = script.reactive();
        vm.chainId(Testnet.BASE_SEPOLIA);
        Executor base = script.executor(address(rc));
        address other = makeAddr("other");
        vm.prank(other, other);
        vm.expectRevert(abi.encodeWithSelector(PairDeploy.NotOwner.selector, deployer));
        script.fund(address(base));
    }

    /// Puts a PoolManager with the demo pool open, USDC and HUNT at the chain's real addresses.
    function _standIns(uint256 chainId) internal {
        address manager = Testnet.poolManager(chainId);
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), manager);
        deployCodeTo("MockToken.sol:MockToken", abi.encode("USDC", uint8(6)), Testnet.usdc(chainId));
        deployCodeTo("MockToken.sol:MockToken", abi.encode("HUNT", uint8(18)), DemoPair.token(chainId));
        MockToken(Testnet.usdc(chainId)).mint(deployer, DemoPair.INVENTORY_USDC);
        MockToken(DemoPair.token(chainId)).mint(deployer, DemoPair.INVENTORY_TOKEN);
        PoolKey memory key = script.poolKey(chainId);
        bool usdcIs0 = Currency.unwrap(key.currency0) == Testnet.usdc(chainId);
        (uint256 a0, uint256 a1) = usdcIs0 ? (uint256(400e6), uint256(40_000e18)) : (uint256(40_000e18), uint256(400e6));
        IPoolManager(manager).initialize(key, uint160(Math.sqrt(a1 * (1 << 96) / a0 * (1 << 96))));
    }
}
