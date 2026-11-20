// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Executor} from "../../src/executor/Executor.sol";
import {SpreadHunterReactive} from "../../src/reactive/SpreadHunterReactive.sol";
import {MockSystem} from "../utils/MockSystem.sol";
import {MockToken} from "../utils/MockToken.sol";

/// Two real pools on Uniswap's PoolManager stand in for the two chains; logs are fed to the reactive contract
/// the way Reactive Network delivers them, and callbacks are delivered the way the callback proxy does.
abstract contract SpreadHunterReactiveTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CHAIN_A = 84532;
    uint256 internal constant CHAIN_B = 1301;
    uint256 internal constant SWAP_TOPIC0 = 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f;
    uint256 internal constant POOL_USDC = 400e6;
    uint256 internal constant POOL_TOKEN = 40_000e18;
    uint256 internal constant INV_USDC = 100e6;
    uint256 internal constant INV_TOKEN = 10_000e18;

    event TradeRequested(
        uint256 indexed nonce,
        uint8 cheapSide,
        uint256 usdcIn,
        uint256 tokenAmount,
        uint256 expectedProfit,
        uint256 originTxHash,
        uint256 requestedAt
    );
    event TradeClosed(uint256 indexed nonce, bool timedOut, bool legFailed, uint256 closedAt);
    event AutoPaused(uint8 failuresInARow);

    MockSystem internal sys;
    MockSystem internal proxy;
    IPoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    MockToken internal usdc;
    MockToken internal token;
    PoolKey internal keyA;
    PoolKey internal keyB;
    Executor internal exA;
    Executor internal exB;
    SpreadHunterReactive internal rc;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    uint256 internal logIndex;
    uint256 internal relayed;

    address internal constant LOW = address(0x10000);
    address internal constant HIGH = address(0x20000);

    function usdcFirst() internal pure virtual returns (bool);

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        proxy = new MockSystem();
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        (address usdcAt, address tokenAt) = usdcFirst() ? (LOW, HIGH) : (HIGH, LOW);
        deployCodeTo("MockToken.sol:MockToken", abi.encode("USDC", uint8(6)), usdcAt);
        deployCodeTo("MockToken.sol:MockToken", abi.encode("TOK", uint8(18)), tokenAt);
        usdc = MockToken(usdcAt);
        token = MockToken(tokenAt);
        usdc.mint(address(this), 1_000_000e6);
        token.mint(address(this), 100_000_000e18);
        usdc.approve(address(lpRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        keyA = _openPool(10);
        keyB = _openPool(60);

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        rc = new SpreadHunterReactive{value: 1 ether}(_pool(CHAIN_A, keyA), _pool(CHAIN_B, keyB), _params());
        exA = new Executor(IPayable(payable(address(proxy))), address(rc), manager, keyA, address(usdc), owner);
        exB = new Executor(IPayable(payable(address(proxy))), address(rc), manager, keyB, address(usdc), owner);
        vm.prank(owner);
        rc.link(address(exA), address(exB));
        for (uint256 i; i < 2; ++i) {
            Executor ex = i == 0 ? exA : exB;
            usdc.mint(address(ex), INV_USDC);
            token.mint(address(ex), INV_TOKEN);
            vm.deal(address(ex), 1 ether);
        }
    }

    // --- subscriptions and access ---

    function test_swapTopic_matchesUniswapEvent() public pure {
        assertEq(uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")), SWAP_TOPIC0);
    }

    function test_subscribesToBothPoolsThenBothExecutors() public view {
        assertEq(sys.subCount(), 8);
        (uint256 c0, address t0, uint256 s0) = sys.subs(0);
        (uint256 c1, address t1, uint256 s1) = sys.subs(1);
        assertEq(c0, CHAIN_A);
        assertEq(c1, CHAIN_B);
        assertEq(t0, address(manager));
        assertEq(t1, address(manager));
        assertEq(s0, SWAP_TOPIC0);
        assertEq(s1, SWAP_TOPIC0);
        (uint256 c2, address t2,) = sys.subs(2);
        (uint256 c5, address t5,) = sys.subs(5);
        assertEq(c2, CHAIN_A);
        assertEq(t2, address(exA));
        assertEq(c5, CHAIN_B);
        assertEq(t5, address(exB));
    }

    function test_link_onlyOnceAndOnlyOwner() public {
        vm.prank(owner);
        vm.expectRevert(SpreadHunterReactive.AlreadyLinked.selector);
        rc.link(address(exA), address(exB));
        vm.prank(stranger);
        vm.expectRevert(SpreadHunterReactive.NotOwner.selector);
        rc.link(address(exA), address(exB));
    }

    function test_react_onlySystem() public {
        IReactive.LogRecord memory l = _swapLog(CHAIN_A, keyA, stranger, 1 << 96, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM));
        rc.react(l);
    }

    function test_constructor_rejectsBadConfig() public {
        SpreadHunterReactive.Pool memory a = _pool(CHAIN_A, keyA);
        SpreadHunterReactive.Pool memory sameChain = _pool(CHAIN_A, keyB);
        vm.expectRevert(SpreadHunterReactive.BadPool.selector);
        new SpreadHunterReactive(a, sameChain, _params());
        SpreadHunterReactive.Pool memory noId = _pool(CHAIN_B, keyB);
        noId.poolId = bytes32(0);
        vm.expectRevert(SpreadHunterReactive.BadPool.selector);
        new SpreadHunterReactive(a, noId, _params());
    }

    function test_setParams_enforcesHardCaps() public {
        SpreadHunterReactive.Params memory p = _params();
        vm.startPrank(owner);
        p.slippageBps = 501;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        p = _params();
        p.legTimeout = 4;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        p = _params();
        p.callbackGas = 299_999;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        p = _params();
        p.maxTradeUsdc = 0;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        p = _params();
        p.maxTradeUsdc = 1_000_000e6 + 1;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        p = _params();
        p.slippageBps = 0;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        p = _params();
        p.minProfitUsdc = 0;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        p = _params();
        p.legTimeout = 601;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        p = _params();
        p.callbackGas = 900_001;
        vm.expectRevert(SpreadHunterReactive.BadParams.selector);
        rc.setParams(p);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(SpreadHunterReactive.NotOwner.selector);
        rc.setParams(_params());
    }

    function test_withdraw_settlesDebtFirst() public {
        sys.setDebt(address(rc), 0.1 ether);
        vm.prank(owner);
        rc.withdraw(0.5 ether);
        assertEq(sys.debt(address(rc)), 0);
        assertEq(owner.balance, 0.5 ether);
    }

    // --- the full loop ---

    function test_fullLoop_closesTheGapAndKeepsTheProfit() public {
        _ready();
        uint256 usdcBefore = usdc.balanceOf(address(exA)) + usdc.balanceOf(address(exB));
        uint256 tokenBefore = token.balanceOf(address(exA)) + token.balanceOf(address(exB));

        vm.recordLogs();
        _swap(keyB, true, 20e6); // someone buys the token on B: it is now ~10% dearer there
        _feedRecorded();
        assertEq(sys.requestCount(), 2);
        ISystemContract.CallbackConfiguration_V_1_0 memory legA = sys.request(0);
        ISystemContract.CallbackConfiguration_V_1_0 memory legB = sys.request(1);
        assertEq(legA.chainId, CHAIN_A);
        assertEq(legA.recipient, address(exA));
        assertEq(legB.chainId, CHAIN_B);
        assertEq(legB.recipient, address(exB));
        assertTrue(rc.flight().active);

        _relayAll();

        uint256 usdcAfter = usdc.balanceOf(address(exA)) + usdc.balanceOf(address(exB));
        uint256 tokenAfter = token.balanceOf(address(exA)) + token.balanceOf(address(exB));
        assertGt(usdcAfter, usdcBefore);
        // leg B sells the amount the reactive contract expected leg A to buy; rounding leaves dust
        assertApproxEqRel(tokenAfter, tokenBefore, 1e10);
        assertFalse(rc.flight().active);
        // what is left of the gap is below the two pool fees
        assertLt(_gapBps(), 11);
    }

    function test_fullLoop_closesWithInventoryReportedAfterTheLegs() public {
        _ready();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        vm.recordLogs();
        _relayAll();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool closed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(rc) && logs[i].topics[0] == TradeClosed.selector) {
                (bool timedOut, bool legFailed,) = abi.decode(logs[i].data, (bool, bool, uint256));
                assertFalse(timedOut);
                assertFalse(legFailed);
                closed = true;
            }
        }
        assertTrue(closed);
        SpreadHunterReactive.Side memory a = rc.sideState(0);
        assertEq(a.usdc, usdc.balanceOf(address(exA)));
        assertEq(a.token, token.balanceOf(address(exA)));
    }

    function test_noTrade_untilBothSidesArePricedAndStocked() public {
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        assertEq(sys.requestCount(), 0);
    }

    function test_noTrade_whenGapIsBelowFees() public {
        _ready();
        vm.recordLogs();
        _swap(keyB, true, 0.01e6);
        _feedRecorded();
        assertEq(sys.requestCount(), 0);
    }

    function test_noTrade_belowMinimumProfit() public {
        _ready();
        SpreadHunterReactive.Params memory p = _params();
        p.minProfitUsdc = 10e6;
        vm.prank(owner);
        rc.setParams(p);
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        assertEq(sys.requestCount(), 0);
    }

    function test_noTrade_whenPaused() public {
        _ready();
        vm.prank(owner);
        rc.setPaused(true);
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        assertEq(sys.requestCount(), 0);
    }

    function test_ownSwaps_doNotStartATrade() public {
        _ready();
        (uint160 p,,,) = manager.getSlot0(keyB.toId());
        _react(
            _swapLog(CHAIN_B, keyB, address(exB), uint160(uint256(p) * 105 / 100), manager.getLiquidity(keyB.toId()))
        );
        assertEq(sys.requestCount(), 0);
    }

    function test_inFlight_blocksASecondTrade() public {
        _ready();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        assertEq(sys.requestCount(), 2);
    }

    function test_lostLeg_unlocksAfterDeadlineThenWaitsTheCooldown() public {
        _ready();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        vm.warp(rc.flight().openUntil + 1);
        vm.recordLogs();
        _swap(keyB, true, 1e6);
        _feedRecorded();
        assertFalse(rc.flight().active);
        assertEq(sys.requestCount(), 2);
        assertEq(rc.failuresInARow(), 1);

        vm.warp(rc.cooldownUntil());
        vm.recordLogs();
        _swap(keyB, true, 1e6);
        _feedRecorded();
        assertEq(sys.requestCount(), 4);
    }

    function test_lostLeg_cannotExecuteAfterUnlock() public {
        _ready();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        vm.warp(rc.flight().openUntil + 1);
        vm.recordLogs();
        _relay(0);
        assertEq(usdc.balanceOf(address(exA)), INV_USDC);
    }

    function test_failedLeg_stillClosesTheFlight() public {
        _ready();
        vm.prank(owner);
        exA.setPaused(true);
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        _relayAll();
        assertFalse(rc.flight().active);
        assertEq(rc.failuresInARow(), 1);
        assertGt(rc.cooldownUntil(), block.timestamp);
    }

    function test_failedTrade_doesNotRepeatWithoutANewSwap() public {
        _ready();
        _pauseExecutors();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        _relayAll();
        assertEq(sys.requestCount(), 2);
        assertEq(relayed, 2);
    }

    function test_threeFailedTrades_pauseTheContract() public {
        _ready();
        _pauseExecutors();
        uint256 clock = vm.getBlockTimestamp();
        for (uint256 i; i < 3; ++i) {
            clock += 61;
            vm.warp(clock);
            vm.recordLogs();
            _swap(keyB, true, 5e6);
            _feedRecorded();
            _relayAll();
        }
        assertEq(sys.requestCount(), 6);
        assertTrue(rc.paused());
        clock += 61;
        vm.warp(clock);
        vm.recordLogs();
        _swap(keyB, true, 5e6);
        _feedRecorded();
        assertEq(sys.requestCount(), 6);

        vm.prank(owner);
        rc.setPaused(false);
        assertEq(rc.failuresInARow(), 0);
    }

    function test_goodTrade_clearsTheFailureCount() public {
        _ready();
        vm.prank(owner);
        exA.setPaused(true);
        uint256 clock = vm.getBlockTimestamp();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        _relayAll();
        assertEq(rc.failuresInARow(), 1);

        vm.prank(owner);
        exA.setPaused(false);
        clock += 61;
        vm.warp(clock);
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        _relayAll();
        assertEq(rc.failuresInARow(), 0);
    }

    function test_lock_staysClosedUntilInventoryFollowsTheResults() public {
        _ready();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        for (uint256 i; i < 2; ++i) {
            vm.recordLogs();
            _relay(relayed++);
            _feedRecordedExcept(uint256(keccak256("Inventory(uint256,uint256)")));
        }
        assertTrue(rc.flight().active);
        _syncBoth();
        assertFalse(rc.flight().active);
    }

    function test_tradeSize_isCutToMaxTrade() public {
        _ready();
        SpreadHunterReactive.Params memory p = _params();
        p.maxTradeUsdc = 2e6;
        vm.prank(owner);
        rc.setParams(p);
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        (,,, uint256 amountIn,,,) = _decodeLeg(sys.request(0).payload);
        assertEq(amountIn, 2e6);
    }

    function test_logsFromOtherContractsOrPools_areIgnored() public {
        _ready();
        (uint160 p,,,) = manager.getSlot0(keyB.toId());
        uint128 liq = manager.getLiquidity(keyB.toId());
        uint160 moved = uint160(uint256(p) * 105 / 100);
        IReactive.LogRecord memory l = _swapLog(CHAIN_B, keyB, stranger, moved, liq);
        l.contractAddress = stranger;
        _react(l);
        _react(_swapLog(CHAIN_B, keyA, stranger, moved, liq));
        _react(_swapLog(777, keyB, stranger, moved, liq));
        assertEq(sys.requestCount(), 0);
        assertEq(rc.sideState(1).sqrtPriceX96, p);
    }

    function test_ownerOnly_pauseAndWithdraw() public {
        vm.startPrank(stranger);
        vm.expectRevert(SpreadHunterReactive.NotOwner.selector);
        rc.setPaused(true);
        vm.expectRevert(SpreadHunterReactive.NotOwner.selector);
        rc.withdraw(1);
        vm.stopPrank();
    }

    function test_staleSwap_neitherMovesThePriceNorTrades() public {
        _ready();
        SpreadHunterReactive.Side memory before = rc.sideState(1);
        IReactive.LogRecord memory l =
            _swapLog(CHAIN_B, keyB, stranger, uint160(uint256(before.sqrtPriceX96) * 105 / 100), before.liquidity);
        l.blockNumber = 0;
        l.logIndex = 0;
        _react(l);
        assertEq(rc.sideState(1).sqrtPriceX96, before.sqrtPriceX96);
        assertEq(sys.requestCount(), 0);
    }

    function test_inventoryAtTheSamePosition_isIgnored() public {
        _ready();
        SpreadHunterReactive.Side memory before = rc.sideState(0);
        IReactive.LogRecord memory l;
        l.chainId = CHAIN_A;
        l.contractAddress = address(exA);
        l.topic0 = uint256(keccak256("Inventory(uint256,uint256)"));
        l.data = abi.encode(uint256(1), uint256(1));
        l.blockNumber = before.inventoryAt >> 64;
        l.logIndex = uint64(before.inventoryAt);
        _react(l);
        assertEq(rc.sideState(0).usdc, before.usdc);
    }

    function test_lock_needsInventoryFromBothSides() public {
        _ready();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        for (uint256 i; i < 2; ++i) {
            vm.recordLogs();
            _relay(relayed++);
            _feedRecordedExcept(uint256(keccak256("Inventory(uint256,uint256)")));
        }
        vm.recordLogs();
        vm.prank(owner);
        exA.sync();
        _feedRecorded();
        assertTrue(rc.flight().active);
    }

    function test_tradeSize_isCutToTheUsdcOnTheCheapSide() public {
        _ready();
        vm.prank(owner);
        exA.withdraw(Currency.wrap(address(usdc)), INV_USDC - 1e6);
        vm.recordLogs();
        _syncBoth();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        (,,, uint256 amountIn,,,) = _decodeLeg(sys.request(0).payload);
        assertLe(amountIn, 1e6);
    }

    function test_autoPause_isAnnouncedEvenWhenAlreadyPaused() public {
        _ready();
        _pauseExecutors();
        uint256 clock = vm.getBlockTimestamp();
        for (uint256 i; i < 2; ++i) {
            clock += 61;
            vm.warp(clock);
            vm.recordLogs();
            _swap(keyB, true, 5e6);
            _feedRecorded();
            _relayAll();
        }
        clock += 61;
        vm.warp(clock);
        vm.recordLogs();
        _swap(keyB, true, 5e6);
        _feedRecorded();
        vm.prank(owner);
        rc.setPaused(true);
        _relayAll();
        // events the reactive contract emitted while the last results were delivered
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool announced;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(rc) && logs[i].topics[0] == AutoPaused.selector) announced = true;
        }
        assertTrue(announced);
        assertEq(rc.failuresInARow(), 3);
    }

    function test_olderInventory_isIgnored() public {
        _ready();
        SpreadHunterReactive.Side memory before = rc.sideState(0);
        IReactive.LogRecord memory l;
        l.chainId = CHAIN_A;
        l.contractAddress = address(exA);
        l.topic0 = uint256(keccak256("Inventory(uint256,uint256)"));
        l.data = abi.encode(uint256(1), uint256(1));
        l.blockNumber = 0;
        _react(l);
        SpreadHunterReactive.Side memory after_ = rc.sideState(0);
        assertEq(after_.usdc, before.usdc);
        assertEq(after_.token, before.token);
    }

    function test_tradeSize_isCutToTheTokenOnTheDearSide() public {
        _ready();
        vm.prank(owner);
        exB.withdraw(Currency.wrap(address(token)), INV_TOKEN - 100e18);
        vm.recordLogs();
        exB.coverDebt();
        _syncBoth();
        vm.recordLogs();
        _swap(keyB, true, 20e6);
        _feedRecorded();
        assertEq(sys.requestCount(), 2);
        (,,, uint256 amountIn,,,) = _decodeLeg(sys.request(1).payload);
        assertLe(amountIn, 100e18);
    }

    // --- helpers ---

    function _params() internal pure returns (SpreadHunterReactive.Params memory) {
        return SpreadHunterReactive.Params({
            minProfitUsdc: 0.01e6, maxTradeUsdc: 50e6, slippageBps: 50, legTimeout: 60, callbackGas: 400_000
        });
    }

    function _pool(uint256 chainId, PoolKey memory k) internal view returns (SpreadHunterReactive.Pool memory) {
        return SpreadHunterReactive.Pool({
            chainId: chainId,
            poolManager: address(manager),
            poolId: PoolId.unwrap(k.toId()),
            usdcIsCurrency0: Currency.unwrap(k.currency0) == address(usdc),
            fee: k.fee
        });
    }

    function _openPool(int24 spacing) internal returns (PoolKey memory k) {
        (address c0, address c1) =
            address(usdc) < address(token) ? (address(usdc), address(token)) : (address(token), address(usdc));
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 500,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
        (uint256 a0, uint256 a1) = c0 == address(usdc) ? (POOL_USDC, POOL_TOKEN) : (POOL_TOKEN, POOL_USDC);
        manager.initialize(k, uint160(Math.sqrt(FullMath.mulDiv(a1, 1 << 192, a0))));
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(spacing),
                tickUpper: TickMath.maxUsableTick(spacing),
                liquidityDelta: int256(Math.sqrt(POOL_USDC * POOL_TOKEN)),
                salt: 0
            }),
            ""
        );
    }

    /// Prices both sides with a dust swap each and reports both inventories.
    function _ready() internal {
        vm.recordLogs();
        _swap(keyA, true, 1);
        _swap(keyB, true, 1);
        _syncBoth();
    }

    function _syncBoth() internal {
        vm.startPrank(owner);
        exA.sync();
        exB.sync();
        vm.stopPrank();
        _feedRecorded();
    }

    function _swap(PoolKey memory k, bool buyToken, uint256 amountIn) internal {
        bool zeroForOne = buyToken == (Currency.unwrap(k.currency0) == address(usdc));
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _feedRecorded() internal {
        _feedRecordedExcept(0);
    }

    function _pauseExecutors() internal {
        vm.startPrank(owner);
        exA.setPaused(true);
        exB.setPaused(true);
        vm.stopPrank();
    }

    /// Delivers the recorded logs, leaving out those with topic0 `skip`.
    function _feedRecordedExcept(uint256 skip) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            uint256 chainId = _chainOf(logs[i]);
            if (chainId == 0 || uint256(logs[i].topics[0]) == skip) continue;
            IReactive.LogRecord memory l;
            l.chainId = chainId;
            l.contractAddress = logs[i].emitter;
            l.topic0 = uint256(logs[i].topics[0]);
            if (logs[i].topics.length > 1) l.topic1 = uint256(logs[i].topics[1]);
            if (logs[i].topics.length > 2) l.topic2 = uint256(logs[i].topics[2]);
            l.data = logs[i].data;
            l.blockNumber = block.number;
            l.logIndex = ++logIndex;
            l.txHash = uint256(keccak256(abi.encode(logIndex)));
            _react(l);
        }
    }

    function _chainOf(Vm.Log memory l) internal view returns (uint256) {
        if (l.emitter == address(exA)) return CHAIN_A;
        if (l.emitter == address(exB)) return CHAIN_B;
        if (l.emitter == address(manager) && l.topics.length > 1) {
            if (l.topics[1] == PoolId.unwrap(keyA.toId())) return CHAIN_A;
            if (l.topics[1] == PoolId.unwrap(keyB.toId())) return CHAIN_B;
        }
        return 0;
    }

    function _react(IReactive.LogRecord memory l) internal {
        vm.prank(SYSTEM);
        rc.react(l);
    }

    /// Delivers every pending callback as the proxy does, with the reactive contract's address as first argument.
    /// Bounded, so a contract that keeps asking for legs fails the test instead of hanging it.
    function _relayAll() internal {
        for (uint256 n; n < 10 && relayed < sys.requestCount(); ++n) {
            vm.recordLogs();
            _relay(relayed++);
            _feedRecorded();
        }
    }

    function _relay(uint256 i) internal {
        ISystemContract.CallbackConfiguration_V_1_0 memory req = sys.request(i);
        bytes memory payload = req.payload;
        address sender = address(rc);
        assembly ("memory-safe") {
            mstore(add(payload, 36), sender)
        }
        vm.prank(address(proxy));
        (bool ok,) = req.recipient.call{gas: req.gasLimit}(payload);
        assertTrue(ok);
    }

    function _decodeLeg(bytes memory payload)
        internal
        pure
        returns (address, bytes32, bool, uint256, uint256, uint160, uint256)
    {
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = payload[i + 4];
        }
        return abi.decode(args, (address, bytes32, bool, uint256, uint256, uint160, uint256));
    }

    function _swapLog(uint256 chainId, PoolKey memory k, address sender, uint160 sqrtPriceX96, uint128 liquidity)
        internal
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = chainId;
        l.contractAddress = address(manager);
        l.topic0 = SWAP_TOPIC0;
        l.topic1 = uint256(PoolId.unwrap(k.toId()));
        l.topic2 = uint256(uint160(sender));
        l.data = abi.encode(int128(0), int128(0), sqrtPriceX96, liquidity, int24(0), uint24(500));
        l.blockNumber = block.number;
        l.logIndex = ++logIndex;
    }

    /// Gap between the two pools' token prices, in basis points of the lower one.
    function _gapBps() internal view returns (uint256) {
        (uint160 pa,,,) = manager.getSlot0(keyA.toId());
        (uint160 pb,,,) = manager.getSlot0(keyB.toId());
        (uint256 hi, uint256 lo) = pa > pb ? (uint256(pa), uint256(pb)) : (uint256(pb), uint256(pa));
        // price ratio is the square of the sqrt-price ratio
        return (FullMath.mulDiv(hi * hi / lo, 10_000, lo)) - 10_000;
    }
}

contract SpreadHunterReactiveUsdcFirstTest is SpreadHunterReactiveTestBase {
    function usdcFirst() internal pure override returns (bool) {
        return true;
    }
}

contract SpreadHunterReactiveTokenFirstTest is SpreadHunterReactiveTestBase {
    function usdcFirst() internal pure override returns (bool) {
        return false;
    }
}
