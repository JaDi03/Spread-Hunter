// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {HuntToken} from "./HuntToken.sol";

/// @title TokenBridge
/// @notice Moves HUNT inventory to the peer chain: burns here and emits a request that the reactive contract
/// turns into a mint on the peer bridge. Only operators can bridge, since every request costs a reaction and
/// a callback.
contract TokenBridge is AbstractCallback {
    error NotOwner();
    error NotOperator();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPeerChain();
    error UnknownRequest(uint256 nonce);
    error WrongSourceChain(uint256 srcChainId);
    error AlreadyMinted(uint256 srcChainId, uint256 nonce);

    struct Request {
        address from;
        address to;
        uint256 amount;
    }

    address public immutable owner;
    HuntToken public immutable token;
    /// @notice The only chain this bridge sends to and accepts mints from.
    uint256 public immutable peerChainId;

    uint256 public nextNonce;
    mapping(address => bool) public operators;
    mapping(uint256 => Request) public requests;
    mapping(uint256 => mapping(uint256 => bool)) public minted;

    event OperatorSet(address indexed operator, bool allowed);
    event BridgeRequested(
        uint256 indexed nonce, address indexed from, address indexed to, uint256 amount, uint256 destinationChainId
    );
    event Minted(uint256 indexed srcChainId, uint256 indexed nonce, address indexed to, uint256 amount);

    constructor(IPayable callbackProxy_, address reactiveContract_, HuntToken token_, uint256 peerChainId_)
        payable
        AbstractCallback(callbackProxy_, reactiveContract_)
    {
        if (address(callbackProxy_) == address(0) || reactiveContract_ == address(0) || address(token_) == address(0)) revert ZeroAddress();
        if (peerChainId_ == 0 || peerChainId_ == block.chainid) revert InvalidPeerChain();
        owner = msg.sender;
        token = token_;
        peerChainId = peerChainId_;
        // nonces start at a per-deployment offset, so a redeployed bridge never reuses a nonce the peer already minted
        nextNonce = uint256(uint160(address(this))) << 96;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Burns `amount` of the caller's HUNT and asks for the same amount to be minted to `to` on the peer chain.
    function bridge(address to, uint256 amount) external returns (uint256 nonce) {
        if (!operators[msg.sender]) revert NotOperator();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        nonce = nextNonce++;
        requests[nonce] = Request(msg.sender, to, amount);
        emit BridgeRequested(nonce, msg.sender, to, amount, peerChainId);
        // a failed burn reverts the whole call, so the request above never exists without the burn
        token.bridgeBurn(msg.sender, amount);
    }

    /// @notice Emits a stored request again when its mint did not land; the peer rejects a second mint.
    function retry(uint256 nonce) external onlyOwner {
        Request memory request = requests[nonce];
        if (request.to == address(0)) revert UnknownRequest(nonce);
        emit BridgeRequested(nonce, request.from, request.to, request.amount, peerChainId);
    }

    function mintFromReactive(address reactive_, uint256 srcChainId, uint256 nonce, address to, uint256 amount)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        if (srcChainId != peerChainId) revert WrongSourceChain(srcChainId);
        if (minted[srcChainId][nonce]) revert AlreadyMinted(srcChainId, nonce);
        minted[srcChainId][nonce] = true;
        emit Minted(srcChainId, nonce, to, amount);
        token.mint(to, amount);
    }

    /// @notice Settles any debt with the callback proxy from this contract's balance.
    function coverDebt() external onlyOwner {
        _coverDebt();
    }

    /// @notice Settles any outstanding debt first, then returns leftover gas funds to the owner.
    function withdraw(uint256 amount) external onlyOwner {
        _coverDebt();
        _pay(payable(owner), amount);
    }
}
