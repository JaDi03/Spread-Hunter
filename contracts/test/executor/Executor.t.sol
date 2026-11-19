// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Executor} from "../../src/executor/Executor.sol";
import {MockSystem} from "../utils/MockSystem.sol";
import {MockToken} from "../utils/MockToken.sol";

/// Runs every test with USDC as currency0 and again as currency1, so both swap directions are covered.
abstract contract ExecutorTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant FEE = 500;
    int24 internal constant SPACING = 10;
    uint256 internal constant POOL_USDC = 400e6;
    uint256 internal constant POOL_TOKEN = 40_000e18;
    uint256 internal constant INV_USDC = 100e6;
    uint256 internal constant INV_TOKEN = 10_000e18;

    event LegExecuted(bytes32 indexed legId, bool buyToken, uint256 paid, uint256 received);
    event LegFailed(bytes32 indexed legId, bytes reason);
    event Inventory(uint256 usdc, uint256 token);

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    MockSystem internal proxy;
    MockToken internal usdc;
    MockToken internal token;
    PoolKey internal key;
    Executor internal ex;

    address internal rc = makeAddr("rc");
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    address internal constant LOW = address(0x10000);
    address internal constant HIGH = address(0x20000);

    function usdcFirst() internal pure virtual returns (bool);

    function setUp() public {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        lpRouter = new PoolModifyLiquidityTest(manager);
        proxy = new MockSystem();
        (address usdcAt, address tokenAt) = usdcFirst() ? (LOW, HIGH) : (HIGH, LOW);
        deployCodeTo("MockToken.sol:MockToken", abi.encode("USDC", uint8(6)), usdcAt);
        deployCodeTo("MockToken.sol:MockToken", abi.encode("TOK", uint8(18)), tokenAt);
        usdc = MockToken(usdcAt);
        token = MockToken(tokenAt);
        key = _key(address(usdc), address(token), FEE, address(0));
        _openPool(key, POOL_USDC, POOL_TOKEN);

        ex = new Executor(IPayable(payable(address(proxy))), rc, manager, key, address(usdc), owner);
        usdc.mint(address(ex), INV_USDC);
        token.mint(address(ex), INV_TOKEN);
        vm.deal(address(ex), 1 ether);
    }

    // --- legs ---

    function test_buyLeg_paysUsdcAndReceivesTokenAtPoolPrice() public {
        uint256 amountIn = 1e6;
        uint256 expected = _quote(POOL_USDC, POOL_TOKEN, amountIn);
        vm.recordLogs();
        _leg("a", true, amountIn, 0, 0);
        uint256 out = token.balanceOf(address(ex)) - INV_TOKEN;

        assertEq(usdc.balanceOf(address(ex)), INV_USDC - amountIn);
        // the pool charges its fee on the input amount
        assertApproxEqRel(out, expected, 1e14);
        _assertExecuted("a", true, amountIn, out);
        assertTrue(ex.legUsed("a"));
    }

    function test_sellLeg_paysTokenAndReceivesUsdc() public {
        uint256 amountIn = 100e18;
        uint256 expected = _quote(POOL_TOKEN, POOL_USDC, amountIn);
        _leg("b", false, amountIn, 0, 0);
        uint256 out = usdc.balanceOf(address(ex)) - INV_USDC;

        assertEq(token.balanceOf(address(ex)), INV_TOKEN - amountIn);
        assertApproxEqRel(out, expected, 1e14);
    }

    function test_leg_emitsInventoryAfterTrade() public {
        vm.recordLogs();
        _leg("c", true, 1e6, 0, 0);
        (uint256 u, uint256 t) = _lastInventory();
        assertEq(u, usdc.balanceOf(address(ex)));
        assertEq(t, token.balanceOf(address(ex)));
    }

    function test_leg_priceLimitStopsEarlyAndSettlesOnlyWhatWasTaken() public {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        bool usdcIs0 = Currency.wrap(address(usdc)) == key.currency0;
        // buying the token moves the price toward the limit; stop 0.1% away
        uint160 limit = usdcIs0 ? uint160(uint256(price) * 9995 / 10_000) : uint160(uint256(price) * 10_005 / 10_000);
        vm.recordLogs();
        _leg("d", true, 50e6, 0, limit);

        uint256 spent = INV_USDC - usdc.balanceOf(address(ex));
        _assertExecuted("d", true, spent, token.balanceOf(address(ex)) - INV_TOKEN);
        assertGt(spent, 0);
        assertLt(spent, 50e6);
        (uint160 after_,,,) = manager.getSlot0(key.toId());
        assertEq(after_, limit);
    }

    // --- failures never revert and never move funds ---

    function test_leg_belowMinimumFailsWithoutMovingFunds() public {
        vm.recordLogs();
        _leg("e", true, 1e6, type(uint256).max, 0);
        _assertNoFundsMoved();
        assertTrue(ex.legUsed("e"));
        _assertFailedWith("e", Executor.OutputBelowMinimum.selector);
    }

    function test_leg_reusedIdFailsWithoutSecondSwap() public {
        _leg("f", true, 1e6, 0, 0);
        uint256 usdcAfterFirst = usdc.balanceOf(address(ex));
        vm.recordLogs();
        _leg("f", true, 1e6, 0, 0);
        assertEq(usdc.balanceOf(address(ex)), usdcAfterFirst);
        _assertFailedWith("f", Executor.LegReused.selector);
    }

    function test_leg_expiredFailsAndStaysUnused() public {
        vm.recordLogs();
        vm.prank(address(proxy));
        ex.executeLeg(rc, "g", true, 1e6, 0, 0, block.timestamp - 1);
        _assertNoFundsMoved();
        assertFalse(ex.legUsed("g"));
        _assertFailedWith("g", Executor.LegExpired.selector);
    }

    function test_leg_pausedFails() public {
        vm.prank(owner);
        ex.setPaused(true);
        vm.recordLogs();
        _leg("h", true, 1e6, 0, 0);
        _assertNoFundsMoved();
        _assertFailedWith("h", Executor.LegPaused.selector);
    }

    function test_leg_zeroAmountFails() public {
        vm.recordLogs();
        _leg("i", true, 0, 0, 0);
        _assertFailedWith("i", Executor.ZeroAmount.selector);
    }

    function test_leg_moreThanInventoryFailsWithoutMovingFunds() public {
        vm.recordLogs();
        _leg("j", true, INV_USDC + 1, 0, 0);
        _assertNoFundsMoved();
        _assertFailed("j");
    }

    function testFuzz_leg_neverRevertsAndOnlyMovesFundsWhenExecuted(
        bool buyToken,
        uint256 amountIn,
        uint256 minOut,
        uint160 limit
    ) public {
        amountIn = bound(amountIn, 0, buyToken ? INV_USDC * 2 : INV_TOKEN * 2);
        minOut = bound(minOut, 0, 2_000e18);
        vm.recordLogs();
        _leg("z", buyToken, amountIn, minOut, limit);

        bool executed = _executed("z");
        bool moved = usdc.balanceOf(address(ex)) != INV_USDC || token.balanceOf(address(ex)) != INV_TOKEN;
        assertEq(executed, moved);
        assertTrue(executed || _failed("z"));
    }

    // --- access ---

    function test_executeLeg_rejectsStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(proxy)));
        ex.executeLeg(rc, "k", true, 1e6, 0, 0, block.timestamp);
    }

    function test_executeLeg_rejectsOtherReactiveContract() public {
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, rc));
        ex.executeLeg(stranger, "k", true, 1e6, 0, 0, block.timestamp);
    }

    function test_swapExactIn_onlySelf() public {
        vm.prank(stranger);
        vm.expectRevert(Executor.NotSelf.selector);
        ex.swapExactIn(true, 1e6, 0, 0);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.prank(stranger);
        vm.expectRevert(Executor.NotPoolManager.selector);
        ex.unlockCallback(abi.encode(true, uint256(1e6), uint160(0)));
    }

    function test_ownerFunctions_rejectStranger() public {
        vm.startPrank(stranger);
        vm.expectRevert(Executor.NotOwner.selector);
        ex.setPaused(true);
        vm.expectRevert(Executor.NotOwner.selector);
        ex.withdraw(Currency.wrap(address(usdc)), 1);
        vm.expectRevert(Executor.NotOwner.selector);
        ex.withdrawEth(1);
        vm.stopPrank();
    }

    function test_withdraw_sendsToOwnerOnly() public {
        vm.prank(owner);
        ex.withdraw(Currency.wrap(address(usdc)), 10e6);
        assertEq(usdc.balanceOf(owner), 10e6);
        assertEq(usdc.balanceOf(address(ex)), INV_USDC - 10e6);
    }

    function test_withdrawEth_settlesDebtFirst() public {
        proxy.setDebt(address(ex), 0.1 ether);
        vm.prank(owner);
        ex.withdrawEth(0.5 ether);
        assertEq(proxy.debt(address(ex)), 0);
        assertEq(owner.balance, 0.5 ether);
        assertEq(address(ex).balance, 0.4 ether);
    }

    function test_sync_emitsBalances() public {
        vm.expectEmit(address(ex));
        emit Inventory(INV_USDC, INV_TOKEN);
        vm.prank(owner);
        ex.sync();
    }

    function test_sync_rejectsStranger() public {
        vm.prank(stranger);
        vm.expectRevert(Executor.NotOwner.selector);
        ex.sync();
    }

    // --- odd tokens ---

    function test_tokenBalanceReverting_doesNotFreezeUsdcWithdraw() public {
        vm.mockCallRevert(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector, address(ex)), "boom");
        vm.expectEmit(address(ex));
        emit Inventory(INV_USDC - 10e6, 0);
        vm.prank(owner);
        ex.withdraw(Currency.wrap(address(usdc)), 10e6);
        assertEq(usdc.balanceOf(owner), 10e6);
    }

    function test_tokenBalanceReverting_failsLegWithoutReverting() public {
        vm.mockCallRevert(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector, address(ex)), "boom");
        vm.recordLogs();
        _leg("o", true, 1e6, 0, 0);
        assertEq(usdc.balanceOf(address(ex)), INV_USDC);
        _assertFailed("o");
    }

    function test_emptyRevert_stillEmitsLegFailed() public {
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.balanceOf.selector, address(ex)), "");
        vm.recordLogs();
        _leg("p", true, 1e6, 0, 0);
        assertTrue(ex.legUsed("p"));
        _assertFailed("p");
    }

    function test_feeOnTransferToken_cannotPassTheMinimum() public {
        uint256 expected = _quote(POOL_USDC, POOL_TOKEN, 1e6);
        token.setTransferFeeBps(100);
        vm.recordLogs();
        _leg("q", true, 1e6, expected * 999 / 1000, 0);
        _assertNoFundsMoved();
        _assertFailedWith("q", Executor.OutputBelowMinimum.selector);
    }

    // --- constructor ---

    function test_constructor_storesPool() public view {
        assertEq(PoolId.unwrap(ex.poolId()), PoolId.unwrap(key.toId()));
        assertEq(Currency.unwrap(ex.usdc()), address(usdc));
        assertEq(Currency.unwrap(ex.token()), address(token));
        assertEq(PoolId.unwrap(ex.poolKey().toId()), PoolId.unwrap(key.toId()));
    }

    function test_constructor_rejectsHooks() public {
        PoolKey memory k = _key(address(usdc), address(token), FEE, makeAddr("hook"));
        vm.expectRevert(Executor.PoolHasHooks.selector);
        _deploy(k, address(usdc));
    }

    function test_constructor_rejectsDynamicFee() public {
        PoolKey memory k = _key(address(usdc), address(token), 0x800000, address(0));
        vm.expectRevert(Executor.DynamicFee.selector);
        _deploy(k, address(usdc));
    }

    function test_constructor_rejectsPoolWithoutUsdc() public {
        vm.expectRevert(Executor.NotUsdcPool.selector);
        _deploy(key, makeAddr("otherUsdc"));
    }

    function test_constructor_rejectsNativeCurrency() public {
        PoolKey memory k = _key(address(0), address(token), FEE, address(0));
        vm.expectRevert(Executor.NativeCurrency.selector);
        _deploy(k, address(token));
    }

    function test_constructor_rejectsUninitializedPool() public {
        PoolKey memory k = _key(address(usdc), address(token), 3000, address(0));
        vm.expectRevert(Executor.PoolNotInitialized.selector);
        _deploy(k, address(usdc));
    }

    function test_constructor_rejectsUnsortedCurrencies() public {
        PoolKey memory k = key;
        (k.currency0, k.currency1) = (k.currency1, k.currency0);
        vm.expectRevert(Executor.UnsortedCurrencies.selector);
        _deploy(k, address(usdc));
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(Executor.ZeroAddress.selector);
        new Executor(IPayable(payable(address(proxy))), address(0), manager, key, address(usdc), owner);
        vm.expectRevert(Executor.ZeroAddress.selector);
        new Executor(IPayable(payable(address(proxy))), rc, manager, key, address(usdc), address(0));
        vm.expectRevert(Executor.ZeroAddress.selector);
        new Executor(IPayable(payable(address(0))), rc, manager, key, address(usdc), owner);
        vm.expectRevert(Executor.ZeroAddress.selector);
        new Executor(IPayable(payable(address(proxy))), rc, IPoolManager(address(0)), key, address(usdc), owner);
        vm.expectRevert(Executor.ZeroAddress.selector);
        new Executor(IPayable(payable(address(proxy))), rc, manager, key, address(0), owner);
    }

    function test_coverDebt_paysProxyFromOwnEth() public {
        proxy.setDebt(address(ex), 0.2 ether);
        vm.prank(stranger);
        ex.coverDebt();
        assertEq(proxy.debt(address(ex)), 0);
        assertEq(address(ex).balance, 0.8 ether);
    }

    function test_withdrawEth_revertsAboveBalance() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.InsufficientFunds.selector, 2 ether, 1 ether));
        ex.withdrawEth(2 ether);
    }

    // --- gas for sizing the callback gas limit ---

    function test_gas_buyLeg() public {
        vm.prank(address(proxy));
        uint256 before = gasleft();
        ex.executeLeg(rc, "gas", true, 1e6, 0, 0, block.timestamp);
        emit log_named_uint("executeLeg gas (warm test state)", before - gasleft());
    }

    // --- helpers ---

    function _leg(bytes32 legId, bool buyToken, uint256 amountIn, uint256 minOut, uint160 limit) internal {
        vm.prank(address(proxy));
        ex.executeLeg(rc, legId, buyToken, amountIn, minOut, limit, block.timestamp);
    }

    function _deploy(PoolKey memory k, address usdc_) internal returns (Executor) {
        return new Executor(IPayable(payable(address(proxy))), rc, manager, k, usdc_, owner);
    }

    function _key(address a, address b, uint24 fee, address hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: SPACING,
            hooks: IHooks(hooks)
        });
    }

    function _openPool(PoolKey memory k, uint256 usdcAmount, uint256 tokenAmount) internal {
        bool usdcIs0 = Currency.unwrap(k.currency0) == address(usdc);
        (uint256 a0, uint256 a1) = usdcIs0 ? (usdcAmount, tokenAmount) : (tokenAmount, usdcAmount);
        manager.initialize(k, uint160(Math.sqrt(FullMath.mulDiv(a1, 1 << 192, a0))));
        usdc.mint(address(this), usdcAmount * 2);
        token.mint(address(this), tokenAmount * 2);
        usdc.approve(address(lpRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(SPACING),
                tickUpper: TickMath.maxUsableTick(SPACING),
                liquidityDelta: int256(Math.sqrt(usdcAmount * tokenAmount)),
                salt: 0
            }),
            ""
        );
    }

    /// Constant-product output after the fee is charged on the input.
    function _quote(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) internal pure returns (uint256) {
        uint256 net = amountIn * (1e6 - FEE) / 1e6;
        return reserveOut * net / (reserveIn + net);
    }

    function _assertNoFundsMoved() internal view {
        assertEq(usdc.balanceOf(address(ex)), INV_USDC);
        assertEq(token.balanceOf(address(ex)), INV_TOKEN);
    }

    function _assertExecuted(bytes32 legId, bool buyToken, uint256 amountIn, uint256 amountOut) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == LegExecuted.selector && logs[i].topics[1] == legId) {
                (bool b, uint256 inAmt, uint256 outAmt) = abi.decode(logs[i].data, (bool, uint256, uint256));
                assertEq(b, buyToken);
                assertEq(inAmt, amountIn);
                assertEq(outAmt, amountOut);
                return;
            }
        }
        fail();
    }

    function _assertFailedWith(bytes32 legId, bytes4 selector) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == LegFailed.selector && logs[i].topics[1] == legId) {
                bytes memory reason = abi.decode(logs[i].data, (bytes));
                assertEq(bytes4(reason), selector);
                return;
            }
        }
        fail();
    }

    function _assertFailed(bytes32 legId) internal {
        assertTrue(_failed(legId));
    }

    function _failed(bytes32 legId) internal returns (bool) {
        return _hasLog(LegFailed.selector, legId);
    }

    function _executed(bytes32 legId) internal returns (bool) {
        return _hasLog(LegExecuted.selector, legId);
    }

    Vm.Log[] internal _cache;

    function _hasLog(bytes32 topic0, bytes32 legId) internal returns (bool) {
        Vm.Log[] memory fresh = vm.getRecordedLogs();
        for (uint256 i; i < fresh.length; ++i) {
            _cache.push(fresh[i]);
        }
        for (uint256 i; i < _cache.length; ++i) {
            if (_cache[i].topics[0] == topic0 && _cache[i].topics.length > 1 && _cache[i].topics[1] == legId) {
                return true;
            }
        }
        return false;
    }

    function _lastInventory() internal returns (uint256 u, uint256 t) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == Inventory.selector && logs[i - 1].emitter == address(ex)) {
                return abi.decode(logs[i - 1].data, (uint256, uint256));
            }
        }
        fail();
    }
}

contract ExecutorUsdcFirstTest is ExecutorTestBase {
    function usdcFirst() internal pure override returns (bool) {
        return true;
    }
}

contract ExecutorTokenFirstTest is ExecutorTestBase {
    function usdcFirst() internal pure override returns (bool) {
        return false;
    }
}
