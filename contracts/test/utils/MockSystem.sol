// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// Records subscriptions and callback requests the way the Reactive system contract receives them.
/// Also serves as a callback proxy: both expose `debt` and accept payments.
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address target;
        uint256 topic0;
    }

    Sub[] public subs;
    ISystemContract.CallbackConfiguration_V_1_0[] internal requests;
    mapping(address => uint256) public debt;

    receive() external payable {
        uint256 owed = debt[msg.sender];
        debt[msg.sender] = msg.value >= owed ? 0 : owed - msg.value;
    }

    function setDebt(address who, uint256 amount) external {
        debt[who] = amount;
    }

    function subscribe(uint256 chainId, address target, uint256 topic0, uint256, uint256, uint256) external {
        subs.push(Sub(chainId, target, topic0));
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config) external {
        requests.push(config);
    }

    function subCount() external view returns (uint256) {
        return subs.length;
    }

    function requestCount() external view returns (uint256) {
        return requests.length;
    }

    function request(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return requests[i];
    }
}
