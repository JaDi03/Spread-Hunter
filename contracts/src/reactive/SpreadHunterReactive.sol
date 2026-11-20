// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Executor} from "../executor/Executor.sol";
import {ArbMath} from "./ArbMath.sol";

/// @title SpreadHunterReactive
/// @notice Watches one USDC pool on each of two chains and, when buying on the cheaper one and selling on the dearer
/// one pays more than the owner's minimum, asks both Executors to trade in the same reaction.
contract SpreadHunterReactive is AbstractReactive {
    error NotOwner();
    error ZeroAddress();
    error BadPool();
    error BadParams();
    error AlreadyLinked();

    struct Pool {
        uint256 chainId;
        address poolManager;
        bytes32 poolId;
        bool usdcIsCurrency0;
        uint24 fee;
    }

    struct Params {
        uint256 minProfitUsdc;
        uint256 maxTradeUsdc;
        uint16 slippageBps;
        uint32 legTimeout;
        uint64 callbackGas;
    }

    /// What the contract knows about one side, from the pool's swaps and the Executor's events.
    struct Side {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint24 fee;
        bool priced;
        bool stocked;
        uint256 usdc;
        uint256 token;
        uint256 inventoryAt;
        uint256 priceAt;
    }

    struct Flight {
        bool active;
        bool legFailed;
        uint64 openUntil;
        uint256 nonce;
        bytes32[2] legs;
        bool[2] resolved;
        uint256[2] resolvedAt;
    }

    uint256 internal constant SWAP_TOPIC0 =
        uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));
    uint256 internal constant INVENTORY_TOPIC0 = uint256(keccak256("Inventory(uint256,uint256)"));
    uint256 internal constant LEG_EXECUTED_TOPIC0 = uint256(keccak256("LegExecuted(bytes32,bool,uint256,uint256)"));
    uint256 internal constant LEG_FAILED_TOPIC0 = uint256(keccak256("LegFailed(bytes32,bytes)"));

    uint16 internal constant MIN_SLIPPAGE_BPS = 1;
    uint16 internal constant MAX_SLIPPAGE_BPS = 500;
    uint256 internal constant MAX_TRADE_USDC = 1_000_000e6;
    /// After a trade with a failed or lost leg, nothing trades for this long.
    uint256 internal constant FAILURE_COOLDOWN = 60;
    /// This many failed trades in a row pause the contract until the owner resumes it.
    uint8 internal constant MAX_FAILURES_IN_A_ROW = 3;
    uint32 internal constant MIN_LEG_TIMEOUT = 5;
    uint32 internal constant MAX_LEG_TIMEOUT = 600;
    uint64 internal constant MIN_CALLBACK_GAS = 300_000;
    uint64 internal constant MAX_CALLBACK_GAS = 900_000;
    /// Clock slack between Reactive Network and the destination chains before a lost leg stops blocking.
    uint64 internal constant UNLOCK_MARGIN = 60;
    uint256 internal constant BPS = 10_000;

    address public immutable owner;

    Pool[2] internal _pools;
    Side[2] internal _sides;
    address[2] public executors;
    Params public params;
    bool public paused;
    Flight internal _flight;
    uint256 public nonce;
    uint256 public cooldownUntil;
    uint8 public failuresInARow;

    event Linked(address executorA, address executorB);
    event ParamsSet(Params params);
    event PausedSet(bool paused);
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

    constructor(Pool memory poolA, Pool memory poolB, Params memory params_) payable {
        _checkPool(poolA);
        _checkPool(poolB);
        if (poolA.chainId == poolB.chainId) revert BadPool();
        _checkParams(params_);
        owner = msg.sender;
        _pools[0] = poolA;
        _pools[1] = poolB;
        _sides[0].fee = poolA.fee;
        _sides[1].fee = poolB.fee;
        params = params_;
        // two fixed calls to the trusted system contract
        // forge-lint: disable-start(calls-loop)
        for (uint256 i; i < 2; ++i) {
            SYSTEM.subscribe(
                _pools[i].chainId,
                _pools[i].poolManager,
                SWAP_TOPIC0,
                uint256(_pools[i].poolId),
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        // forge-lint: disable-end(calls-loop)
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice One-time link to the two Executors, which need this contract's address when they are deployed.
    function link(address executorA, address executorB) external onlyOwner {
        if (executorA == address(0) || executorB == address(0)) revert ZeroAddress();
        if (executors[0] != address(0)) revert AlreadyLinked();
        executors = [executorA, executorB];
        emit Linked(executorA, executorB);
        uint256[3] memory topics = [INVENTORY_TOPIC0, LEG_EXECUTED_TOPIC0, LEG_FAILED_TOPIC0];
        // six fixed calls to the trusted system contract
        // forge-lint: disable-start(calls-loop)
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 3; ++j) {
                SYSTEM.subscribe(
                    _pools[i].chainId, executors[i], topics[j], REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
            }
        }
        // forge-lint: disable-end(calls-loop)
    }

    function setParams(Params calldata params_) external onlyOwner {
        _checkParams(params_);
        params = params_;
        emit ParamsSet(params_);
    }

    /// @notice Pauses or resumes trading; resuming also clears the count of failed trades.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        if (!paused_) failuresInARow = 0;
        emit PausedSet(paused_);
    }

    /// @notice Settles any debt with the system contract from this contract's balance.
    function coverDebt() external onlyOwner {
        _coverDebt();
    }

    /// @notice Settles debt first, then returns lREACT to the owner. Leave enough for the reactions still to come:
    /// a contract in debt stops reacting.
    function withdraw(uint256 amount) external onlyOwner {
        _coverDebt();
        _pay(payable(owner), amount);
    }

    function pool(uint256 side) external view returns (Pool memory) {
        return _pools[side];
    }

    function sideState(uint256 side) external view returns (Side memory) {
        return _sides[side];
    }

    function flight() external view returns (Flight memory) {
        return _flight;
    }

    function react(LogRecord calldata log_) external onlySystem {
        uint256 side = log_.chainId == _pools[0].chainId ? 0 : log_.chainId == _pools[1].chainId ? 1 : 2;
        if (side == 2) return;
        uint256 at = (log_.blockNumber << 64) | log_.logIndex;
        bool trigger = false;

        if (
            log_.contractAddress == _pools[side].poolManager && log_.topic0 == SWAP_TOPIC0
                && bytes32(log_.topic1) == _pools[side].poolId
        ) {
            Side storage s = _sides[side];
            // a swap delivered late, behind a newer one, is stale: it neither moves the price nor starts a trade
            if (s.priced && at <= s.priceAt) return;
            (,, uint160 sqrtPriceX96, uint128 liquidity,, uint24 fee) =
                abi.decode(log_.data, (int128, int128, uint160, uint128, int24, uint24));
            s.sqrtPriceX96 = sqrtPriceX96;
            s.liquidity = liquidity;
            s.fee = fee;
            s.priced = true;
            s.priceAt = at;
            // our own legs move the price but never start a trade
            trigger = log_.topic2 != uint256(uint160(executors[side]));
        } else if (executors[side] != address(0) && log_.contractAddress == executors[side]) {
            if (log_.topic0 == INVENTORY_TOPIC0) {
                Side storage s = _sides[side];
                if (!s.stocked || at > s.inventoryAt) {
                    (s.usdc, s.token) = abi.decode(log_.data, (uint256, uint256));
                    s.inventoryAt = at;
                    s.stocked = true;
                }
            } else if (log_.topic0 == LEG_EXECUTED_TOPIC0 || log_.topic0 == LEG_FAILED_TOPIC0) {
                if (_flight.active && _flight.legs[side] == bytes32(log_.topic1)) {
                    _flight.resolved[side] = true;
                    _flight.resolvedAt[side] = at;
                    if (log_.topic0 == LEG_FAILED_TOPIC0) _flight.legFailed = true;
                }
            }
        } else {
            return;
        }

        // closing a trade never starts the next one: only a swap someone else made can, so a state that makes
        // legs fail cannot loop
        _closeFlight();
        if (trigger) _tryTrade(log_.txHash);
    }

    /// Opens the lock once both legs have a result and each Executor reported its balances after that result,
    /// or once a lost leg can no longer execute. A failed or lost leg starts a cooldown and counts toward the pause.
    function _closeFlight() internal {
        if (!_flight.active) return;
        bool settled = _flight.resolved[0] && _flight.resolved[1] && _sides[0].inventoryAt > _flight.resolvedAt[0]
            && _sides[1].inventoryAt > _flight.resolvedAt[1];
        // forge-lint: disable-next-line(block-timestamp)
        bool timedOut = block.timestamp > _flight.openUntil;
        if (!settled && !timedOut) return;
        _flight.active = false;
        emit TradeClosed(_flight.nonce, !settled, _flight.legFailed, block.timestamp);

        if (settled && !_flight.legFailed) {
            failuresInARow = 0;
            return;
        }
        cooldownUntil = block.timestamp + FAILURE_COOLDOWN;
        if (++failuresInARow >= MAX_FAILURES_IN_A_ROW) {
            paused = true;
            emit AutoPaused(failuresInARow);
        }
    }

    struct Plan {
        uint256 a;
        uint256 b;
        uint256 usdcA;
        uint256 tokenA;
        uint256 usdcB;
        uint256 tokenB;
        uint256 usdcIn;
        uint256 tokenAmount;
        uint256 usdcOut;
    }

    function _tryTrade(uint256 originTxHash) internal {
        // forge-lint: disable-next-line(block-timestamp)
        if (paused || _flight.active || executors[0] == address(0) || block.timestamp < cooldownUntil) return;
        Side storage s0 = _sides[0];
        Side storage s1 = _sides[1];
        if (!s0.priced || !s1.priced || !s0.stocked || !s1.stocked) return;

        Plan memory p = _plan();
        if (p.usdcIn == 0 || p.usdcOut <= p.usdcIn || p.usdcOut - p.usdcIn < params.minProfitUsdc) return;

        uint256 id = ++nonce;
        uint256 deadline = block.timestamp + params.legTimeout;
        bytes32 legA = keccak256(abi.encode(address(this), id, p.a));
        bytes32 legB = keccak256(abi.encode(address(this), id, p.b));
        _flight = Flight({
            active: true,
            legFailed: false,
            openUntil: SafeCast.toUint64(deadline) + UNLOCK_MARGIN,
            nonce: id,
            legs: p.a == 0 ? [legA, legB] : [legB, legA],
            resolved: [false, false],
            resolvedAt: [uint256(0), uint256(0)]
        });

        // the only external calls here go to the trusted system contract
        // forge-lint: disable-start(reentrancy-events)
        emit TradeRequested(
            id, SafeCast.toUint8(p.a), p.usdcIn, p.tokenAmount, p.usdcOut - p.usdcIn, originTxHash, block.timestamp
        );
        // forge-lint: disable-end(reentrancy-events)
        _requestLeg(p.a, legA, true, p.usdcIn, p.tokenAmount, p.usdcA, deadline);
        _requestLeg(p.b, legB, false, p.tokenAmount, p.usdcOut, p.tokenB, deadline);
    }

    /// Sizes the trade: the profit-maximizing amount, cut to the owner's cap, the USDC on the cheap side and the token
    /// on the dear side.
    function _plan() internal view returns (Plan memory p) {
        (uint256 u0, uint256 t0) =
            ArbMath.reserves(_sides[0].sqrtPriceX96, _sides[0].liquidity, _pools[0].usdcIsCurrency0);
        (uint256 u1, uint256 t1) =
            ArbMath.reserves(_sides[1].sqrtPriceX96, _sides[1].liquidity, _pools[1].usdcIsCurrency0);
        if (u0 == 0 || t0 == 0 || u1 == 0 || t1 == 0) return p;
        (p.a, p.b) = ArbMath.cheaperOnA(u0, t0, u1, t1) ? (0, 1) : (1, 0);
        (p.usdcA, p.tokenA, p.usdcB, p.tokenB) = p.a == 0 ? (u0, t0, u1, t1) : (u1, t1, u0, t0);
        uint24 feeA = _sides[p.a].fee;
        uint24 feeB = _sides[p.b].fee;

        p.usdcIn = ArbMath.optimalUsdcIn(p.usdcA, p.tokenA, feeA, p.usdcB, p.tokenB, feeB);
        if (p.usdcIn > params.maxTradeUsdc) p.usdcIn = params.maxTradeUsdc;
        if (p.usdcIn > _sides[p.a].usdc) p.usdcIn = _sides[p.a].usdc;
        p.tokenAmount = ArbMath.amountOut(p.usdcA, p.tokenA, feeA, p.usdcIn);
        if (p.tokenAmount > _sides[p.b].token) {
            p.usdcIn = ArbMath.amountInFor(p.usdcA, p.tokenA, feeA, _sides[p.b].token);
            p.tokenAmount = ArbMath.amountOut(p.usdcA, p.tokenA, feeA, p.usdcIn);
        }
        p.usdcOut = ArbMath.amountOut(p.tokenB, p.usdcB, feeB, p.tokenAmount);
    }

    function _requestLeg(
        uint256 side,
        bytes32 legId,
        bool buyToken,
        uint256 amountIn,
        uint256 expectedOut,
        uint256 reserveIn,
        uint256 deadline
    ) internal {
        bytes memory payload = abi.encodeCall(
            Executor.executeLeg,
            (
                address(0),
                legId,
                buyToken,
                amountIn,
                expectedOut * (BPS - params.slippageBps) / BPS,
                _priceLimit(side, buyToken, amountIn, reserveIn),
                deadline
            )
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: _pools[side].chainId,
                recipient: executors[side],
                gasLimit: params.callbackGas,
                payload: payload
            })
        );
    }

    /// Price the leg may not pass: where the expected swap leaves the pool, plus the slippage allowance.
    /// @param reserveIn Virtual reserve of the side being paid in.
    function _priceLimit(uint256 side, bool buyToken, uint256 amountIn, uint256 reserveIn)
        internal
        view
        returns (uint160)
    {
        uint16 slip = params.slippageBps;
        bool inputIsCurrency0 = buyToken == _pools[side].usdcIsCurrency0;
        uint256 after_ =
            ArbMath.sqrtPriceAfter(_sides[side].sqrtPriceX96, reserveIn, inputIsCurrency0, _sides[side].fee, amountIn);
        uint256 limit = inputIsCurrency0 ? after_ * (BPS - slip) / BPS : after_ * (BPS + slip) / BPS;
        if (limit <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return SafeCast.toUint160(limit);
    }

    function _checkPool(Pool memory p) internal pure {
        if (p.chainId == 0 || p.poolManager == address(0) || p.poolId == bytes32(0) || p.fee >= ArbMath.PIPS) {
            revert BadPool();
        }
    }

    function _checkParams(Params memory p) internal pure {
        if (
            p.slippageBps < MIN_SLIPPAGE_BPS || p.slippageBps > MAX_SLIPPAGE_BPS || p.minProfitUsdc == 0
                || p.maxTradeUsdc > MAX_TRADE_USDC || p.legTimeout < MIN_LEG_TIMEOUT || p.legTimeout > MAX_LEG_TIMEOUT
                || p.callbackGas < MIN_CALLBACK_GAS || p.callbackGas > MAX_CALLBACK_GAS || p.maxTradeUsdc == 0
        ) revert BadParams();
    }
}
