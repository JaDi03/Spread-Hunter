// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title SpikeEmitter
/// @notice Origin-chain event source for the end-to-end Reactive loop test. Only the owner pings,
/// so nobody else can spend the loop's gas funds or add noise to the latency measurement.
contract SpikeEmitter {
    error NotOwner();

    address public immutable owner;

    event Ping(uint256 indexed value, uint256 sentAt);

    constructor() {
        owner = msg.sender;
    }

    function ping(uint256 value) external {
        if (msg.sender != owner) revert NotOwner();
        emit Ping(value, block.timestamp);
    }
}
