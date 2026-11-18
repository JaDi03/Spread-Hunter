// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// @title SpikeCallback
/// @notice Destination end of the loop test: records what the reactive contract saw and when it landed.
contract SpikeCallback is AbstractCallback {
    error NotOwner();
    error ZeroAddress();

    address public immutable owner;
    uint256 public pongCount;

    event Pong(uint256 value, uint256 thresholdSeen, uint256 sentAt, uint256 landedAt, uint256 originTxHash);

    constructor(IPayable callbackProxy_, address reactiveContract_)
        payable
        AbstractCallback(callbackProxy_, reactiveContract_)
    {
        if (address(callbackProxy_) == address(0) || reactiveContract_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function onPing(address reactive_, uint256 value, uint256 thresholdSeen, uint256 sentAt, uint256 originTxHash)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        pongCount += 1;
        emit Pong(value, thresholdSeen, sentAt, block.timestamp, originTxHash);
    }

    /// @notice Settles any debt with the callback proxy from this contract's balance.
    function coverDebt() external onlyOwner {
        _coverDebt();
    }

    /// @notice Settles any outstanding debt first, so a withdrawal never leaves the loop blocked, then returns
    /// leftover gas funds to the owner.
    function withdraw(uint256 amount) external onlyOwner {
        _coverDebt();
        _pay(payable(owner), amount);
    }
}
