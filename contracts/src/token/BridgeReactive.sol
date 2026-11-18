// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {TokenBridge} from "./TokenBridge.sol";

/// @title BridgeReactive
/// @notice Relays HUNT bridge requests between the two TokenBridges: a BridgeRequested on one chain becomes a
/// mint on the other. It is kept apart from the strategy contract so the bridges never need redeploying when
/// the strategy changes.
contract BridgeReactive is AbstractReactive {
    error NotOwner();
    error ZeroAddress();
    error InvalidChains();
    error BridgesAlreadySet();

    uint64 public constant CALLBACK_GAS_LIMIT = 400_000;
    uint256 public constant BRIDGE_REQUESTED_TOPIC0 =
        uint256(keccak256("BridgeRequested(uint256,address,address,uint256,uint256)"));

    address public immutable owner;
    uint256 public immutable chainA;
    uint256 public immutable chainB;

    address public bridgeA;
    address public bridgeB;

    event BridgesSet(address bridgeA, address bridgeB);
    event Relayed(uint256 indexed srcChainId, uint256 indexed nonce, address to, uint256 amount);
    event Skipped(uint256 indexed srcChainId, uint256 indexed nonce, uint256 destinationChainId);

    constructor(uint256 chainA_, uint256 chainB_) payable {
        if (chainA_ == 0 || chainB_ == 0 || chainA_ == chainB_) revert InvalidChains();
        owner = msg.sender;
        chainA = chainA_;
        chainB = chainB_;
    }

    /// @notice One-time link to the two bridges, which need this contract's address when they are deployed.
    function setBridges(address bridgeA_, address bridgeB_) external {
        if (msg.sender != owner) revert NotOwner();
        if (bridgeA_ == address(0) || bridgeB_ == address(0)) revert ZeroAddress();
        if (bridgeA != address(0)) revert BridgesAlreadySet();
        bridgeA = bridgeA_;
        bridgeB = bridgeB_;
        emit BridgesSet(bridgeA_, bridgeB_);
        SYSTEM.subscribe(chainA, bridgeA_, BRIDGE_REQUESTED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainB, bridgeB_, BRIDGE_REQUESTED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function coverDebt() external {
        if (msg.sender != owner) revert NotOwner();
        _coverDebt();
    }

    /// @notice Settles any outstanding debt first, then returns leftover gas funds to the owner.
    function withdraw(uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        _coverDebt();
        _pay(payable(owner), amount);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != BRIDGE_REQUESTED_TOPIC0) return;

        uint256 destChainId;
        address destBridge;
        if (log_.chainId == chainA && log_.contractAddress == bridgeA && bridgeA != address(0)) {
            (destChainId, destBridge) = (chainB, bridgeB);
        } else if (log_.chainId == chainB && log_.contractAddress == bridgeB && bridgeB != address(0)) {
            (destChainId, destBridge) = (chainA, bridgeA);
        } else {
            return;
        }

        uint256 nonce = log_.topic1;
        (uint256 amount, uint256 requestedDest) = abi.decode(log_.data, (uint256, uint256));
        if (requestedDest != destChainId) {
            emit Skipped(log_.chainId, nonce, requestedDest);
            return;
        }
        // an indexed address is stored left-padded to 32 bytes, so the low 160 bits are the whole value
        // forge-lint: disable-next-line(unsafe-typecast)
        address to = address(uint160(log_.topic3));

        emit Relayed(log_.chainId, nonce, to, amount);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId,
                recipient: destBridge,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeCall(TokenBridge.mintFromReactive, (address(0), log_.chainId, nonce, to, amount))
            })
        );
    }
}
