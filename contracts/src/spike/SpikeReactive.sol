// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @title SpikeReactive
/// @notice Reacts to SpikeEmitter pings and forwards the ones at or above an owner-set threshold
/// to SpikeCallback, carrying the threshold it saw so the owner-update path can be checked on-chain.
contract SpikeReactive is AbstractReactive {
    error NotOwner();
    error CallbackAlreadySet();
    error ZeroAddress();
    error ZeroChainId();

    uint64 private constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 private constant PING_TOPIC0 = uint256(keccak256("Ping(uint256,uint256)"));

    address public immutable owner;
    uint256 public immutable originChainId;
    address public immutable originEmitter;
    uint256 public immutable destinationChainId;

    address public callbackContract;
    uint256 public threshold;
    uint256 public reactCount;

    event ThresholdSet(uint256 threshold);
    event CallbackSet(address callbackContract);
    event Reacted(uint256 value, uint256 thresholdSeen, bool forwarded);

    constructor(uint256 originChainId_, address originEmitter_, uint256 destinationChainId_, uint256 threshold_)
        payable {
        if (originEmitter_ == address(0)) revert ZeroAddress();
        if (originChainId_ == 0 || destinationChainId_ == 0) revert ZeroChainId();
        owner = msg.sender;
        originChainId = originChainId_;
        originEmitter = originEmitter_;
        destinationChainId = destinationChainId_;
        threshold = threshold_;
        SYSTEM.subscribe(originChainId_, originEmitter_, PING_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice One-time link to the destination contract, which needs this contract's address at deploy.
    function setCallbackContract(address callbackContract_) external onlyOwner {
        if (callbackContract_ == address(0)) revert ZeroAddress();
        if (callbackContract != address(0)) revert CallbackAlreadySet();
        callbackContract = callbackContract_;
        emit CallbackSet(callbackContract_);
    }

    function setThreshold(uint256 threshold_) external onlyOwner {
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    /// @notice Settles any debt with the system contract from this contract's balance.
    function coverDebt() external onlyOwner {
        _coverDebt();
    }

    /// @notice Settles any outstanding debt first, so a withdrawal never leaves the loop blocked, then returns
    /// leftover gas funds to the owner.
    function withdraw(uint256 amount) external onlyOwner {
        _coverDebt();
        _pay(payable(owner), amount);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != originChainId || log_.contractAddress != originEmitter || log_.topic0 != PING_TOPIC0) {
            return;
        }
        uint256 value = log_.topic1;
        uint256 sentAt = abi.decode(log_.data, (uint256));
        uint256 seen = threshold;
        reactCount += 1;

        bool forward = value >= seen && callbackContract != address(0);
        emit Reacted(value, seen, forward);
        if (forward) {
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: destinationChainId,
                    recipient: callbackContract,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: abi.encodeWithSignature(
                        "onPing(address,uint256,uint256,uint256,uint256)", address(0), value, seen, sentAt, log_.txHash
                    )
                })
            );
        }
    }
}
