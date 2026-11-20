// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Executor
/// @notice Holds one owner's USDC and token inventory on one chain and trades it on one Uniswap V4 pool,
/// one leg per callback from the owner's reactive contract.
contract Executor is AbstractCallback, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error ZeroAddress();
    error UnsortedCurrencies();
    error PoolNotInitialized();
    error NotUsdcPool();
    error NativeCurrency();
    error PoolHasHooks();
    error DynamicFee();
    error NotOwner();
    error NotSelf();
    error NotPoolManager();
    error LegExpired();
    error LegPaused();
    error LegReused();
    error ZeroAmount();
    error ZeroMinimum();
    error OutputBelowMinimum(uint256 amountOut, uint256 minAmountOut);

    event LegExecuted(bytes32 indexed legId, bool buyToken, uint256 paid, uint256 received);
    event LegFailed(bytes32 indexed legId, bytes reason);
    event Inventory(uint256 usdc, uint256 token);
    event PausedSet(bool paused);

    IPoolManager public immutable poolManager;
    address public immutable owner;
    Currency public immutable usdc;
    Currency public immutable token;
    Currency internal immutable _currency0;
    Currency internal immutable _currency1;
    uint24 internal immutable _fee;
    int24 internal immutable _tickSpacing;
    PoolId public immutable poolId;

    uint256 internal constant BALANCE_GAS = 50_000;

    bool public paused;
    mapping(bytes32 legId => bool) public legUsed;

    /// @param reactiveContract The only reactive contract whose callbacks may trade this inventory.
    /// @param key A hookless, static-fee pool of USDC against one ERC-20 token.
    constructor(
        IPayable callbackProxy,
        address reactiveContract,
        IPoolManager poolManager_,
        PoolKey memory key,
        address usdc_,
        address owner_
    ) payable AbstractCallback(callbackProxy, reactiveContract) {
        if (
            address(callbackProxy) == address(0) || reactiveContract == address(0)
                || address(poolManager_) == address(0) || usdc_ == address(0) || owner_ == address(0)
        ) revert ZeroAddress();
        if (!(key.currency0 < key.currency1)) revert UnsortedCurrencies();
        if (key.currency0.isAddressZero()) revert NativeCurrency();
        if (address(key.hooks) != address(0)) revert PoolHasHooks();
        if (LPFeeLibrary.isDynamicFee(key.fee)) revert DynamicFee();

        Currency usdcCurrency = Currency.wrap(usdc_);
        if (key.currency0 == usdcCurrency) {
            token = key.currency1;
        } else if (key.currency1 == usdcCurrency) {
            token = key.currency0;
        } else {
            revert NotUsdcPool();
        }

        poolManager = poolManager_;
        owner = owner_;
        usdc = usdcCurrency;
        _currency0 = key.currency0;
        _currency1 = key.currency1;
        _fee = key.fee;
        _tickSpacing = key.tickSpacing;
        poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager_.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice The pool this executor trades on.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    /// @notice Trades one leg. A leg that fails emits `LegFailed` instead of reverting, so the reactive contract learns
    /// of it; only a callback without gas left for the events reverts as a whole.
    /// @param rvmId Filled in by the callback proxy with the sender reactive contract.
    /// @param buyToken True pays USDC for the token; false sells the token for USDC.
    /// @param sqrtPriceLimitX96 Price at which the swap stops; 0 means no limit.
    function executeLeg(
        address rvmId,
        bytes32 legId,
        bool buyToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external onlyServiceProvider onlyCallbackSender(rvmId) {
        bytes memory reason = _precheck(legId, amountIn, minAmountOut, deadline);
        bool executed = false;
        if (reason.length == 0) {
            legUsed[legId] = true;
            try this.swapExactIn(buyToken, amountIn, minAmountOut, sqrtPriceLimitX96) returns (
                uint256 paid, uint256 received
            ) {
                executed = true;
                // only the callback proxy can enter here and hooked pools are refused, so the result is final
                // forge-lint: disable-next-line(reentrancy-events)
                emit LegExecuted(legId, buyToken, paid, received);
            } catch (bytes memory err) {
                reason = err;
            }
        }
        // forge-lint: disable-next-line(reentrancy-events)
        if (!executed) emit LegFailed(legId, reason);
        _emitInventory();
    }

    /// @dev External only so `executeLeg` can catch its revert; callable by this contract alone.
    /// Paid and received are this contract's own balance changes, so a token that skims transfers cannot pass the minimum.
    function swapExactIn(bool buyToken, uint256 amountIn, uint256 minAmountOut, uint160 sqrtPriceLimitX96)
        external
        returns (uint256 paid, uint256 received)
    {
        if (msg.sender != address(this)) revert NotSelf();
        bool zeroForOne = buyToken == (usdc == _currency0);
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        (Currency input, Currency output) = buyToken ? (usdc, token) : (token, usdc);
        uint256 inputBefore = input.balanceOfSelf();
        uint256 outputBefore = output.balanceOfSelf();
        // forge-lint: disable-next-line(unused-return)
        poolManager.unlock(abi.encode(zeroForOne, amountIn, sqrtPriceLimitX96));
        paid = inputBefore - input.balanceOfSelf();
        received = output.balanceOfSelf() - outputBefore;
        if (received < minAmountOut) revert OutputBelowMinimum(received, minAmountOut);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96) = abi.decode(data, (bool, uint256, uint160));

        BalanceDelta delta = poolManager.swap(
            poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );
        (Currency input, Currency output) = zeroForOne ? (_currency0, _currency1) : (_currency1, _currency0);
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        // a price limit can stop the swap early, so settle what the pool actually took
        uint256 paid = SafeCast.toUint256(-int256(inDelta));
        uint256 received = SafeCast.toUint256(int256(outDelta));
        poolManager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), paid);
        // a short payment leaves a nonzero delta and the pool reverts the whole unlock
        // forge-lint: disable-next-line(unused-return)
        poolManager.settle();
        poolManager.take(output, address(this), received);
        return "";
    }

    /// @notice Emits the current balances so the reactive contract can size the next trade, for example after a deposit.
    /// @dev Owner only: every event the reactive contract receives is paid from its balance.
    function sync() external onlyOwner {
        _emitInventory();
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Sends inventory to the owner only.
    function withdraw(Currency currency, uint256 amount) external onlyOwner {
        IERC20(Currency.unwrap(currency)).safeTransfer(owner, amount);
        _emitInventory();
    }

    /// @notice Sends callback funding to the owner, after settling any debt with the callback proxy.
    function withdrawEth(uint256 amount) external onlyOwner {
        _coverDebt();
        _pay(payable(owner), amount);
    }

    /// @notice Settles debt with the callback proxy from this contract's ETH.
    function coverDebt() external {
        _coverDebt();
    }

    function _precheck(bytes32 legId, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        if (legUsed[legId]) return abi.encodeWithSelector(LegReused.selector);
        if (paused) return abi.encodeWithSelector(LegPaused.selector);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) return abi.encodeWithSelector(LegExpired.selector);
        if (amountIn == 0) return abi.encodeWithSelector(ZeroAmount.selector);
        // a leg with no minimum output would accept any price
        if (minAmountOut == 0) return abi.encodeWithSelector(ZeroMinimum.selector);
        return "";
    }

    /// The last `Inventory` of a leg is emitted after every transfer, so it always holds the final balances.
    function _emitInventory() internal {
        // forge-lint: disable-next-line(reentrancy-events)
        emit Inventory(_balanceOrZero(usdc), _balanceOrZero(token));
    }

    /// Reads a balance without ever reverting: a token whose `balanceOf` fails reports 0, so the reactive contract
    /// never sizes a trade from it and withdrawals keep working. Gas and return data are capped.
    function _balanceOrZero(Currency currency) internal view returns (uint256 amount) {
        address target = Currency.unwrap(currency);
        bool ok;
        assembly ("memory-safe") {
            mstore(0x00, 0x70a08231)
            mstore(0x20, address())
            ok := staticcall(BALANCE_GAS, target, 0x1c, 0x24, 0x00, 0x20)
            if lt(returndatasize(), 0x20) { ok := 0 }
            amount := mload(0x00)
        }
        if (!ok) amount = 0;
    }
}
