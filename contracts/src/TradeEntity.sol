// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {LinkTokenInterface} from "@chainlink/contracts-ccip/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Groth16Verifier} from "./CanfillOrder_verifier.sol";

abstract contract TradeEntity is OwnerIsCreator, CCIPReceiver {
    enum OperationType {
        MESSAGE,
        REQUEST_PUBKEY,
        PROVIDE_PUBKEY,
        REQUEST_PROOF,
        PROVIDE_PROOF
    }

    struct CircomPubkey {
        uint256 Ax;
        uint256 Ay;
    }

    struct EthPubkey {
        bytes32 value;
    }

    struct TradeMessage {
        OperationType operation;
        CircomPubkey circomPubkey;
        EthPubkey ethPubkey;
        // uint256 Ax;
        // uint256 Ay;
        bytes encryptedRequest;
        string message;
        bytes proof;
    }

    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        OperationType operation,
        string text // The text that was received.
    );

    event MessageSent(
        address receiver, // The address of the sender from the source chain.
        OperationType operation,
        string text // The text that was received.
    );

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DestinationChainNotWhitelisted(uint64 destinationChainSelector);
    error NothingToWithdraw();
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector); // Used when the destination chain has not been allowlisted by the contract owner.
    error SourceChainNotAllowlisted(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
    error SenderNotAllowlisted(address sender); // Used when the sender has not been allowlisted by the contract owner.
    error UnknownOperation(); // Used when the sender has not been allowlisted by the contract owner.

    LinkTokenInterface link;
    IRouterClient router;
    CircomPubkey circomPubkey;
    EthPubkey ethPubkey;

    bytes32 internal lastReceivedMessageId; // Store the last received messageId.
    mapping(bytes32 => TradeMessage) public messageStack;
    address verifier;
    mapping(uint64 => bool) public whitelistedChains;

    constructor(address _router, address _link) CCIPReceiver(_router) {
        router = IRouterClient(_router);
        link = LinkTokenInterface(_link);
        verifier = address(new Groth16Verifier());
    }

    modifier onlyWhitelistedChain(uint64 _destinationChainSelector) {
        if (!whitelistedChains[_destinationChainSelector])
            revert DestinationChainNotWhitelisted(_destinationChainSelector);
        _;
    }

    function whitelistChain(
        uint64 _destinationChainSelector
    ) external onlyOwner {
        whitelistedChains[_destinationChainSelector] = true;
    }

    function denylistChain(
        uint64 _destinationChainSelector
    ) external onlyOwner {
        whitelistedChains[_destinationChainSelector] = false;
    }

    function setEthPubkey(bytes32 _ethPubkeyValue) public onlyOwner {
        ethPubkey = EthPubkey({value: _ethPubkeyValue});
    }

    function setCircomPubkey(uint256 Ax, uint256 Ay) public onlyOwner {
        circomPubkey = CircomPubkey({Ax: Ax, Ay: Ay});
    }

    function sendTradeMessage(
        address recipient,
        uint64 recipientChainId,
        TradeMessage memory payload
    )
        internal
        onlyWhitelistedChain(recipientChainId)
        returns (
            bytes32 messageId
        )
    {
        // Prepare the CCIP message
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(recipient),
            data: abi.encode(payload),
            tokenAmounts: new Client.EVMTokenAmount[](0), // No token transfer
            // extraArgs: Client._argsToBytes(
            //     Client.EVMExtraArgsV1({gasLimit: 2_000_000})
            // ),
            extraArgs: "",
            feeToken: address(link)
        });

        // Calculate and verify the CCIP fees
        uint256 ccipFees = router.getFee(recipientChainId, ccipMessage);
        if (ccipFees > link.balanceOf(address(this))) {
            revert NotEnoughBalance(link.balanceOf(address(this)), ccipFees);
        }

        // Approve and process the CCIP fee payment
        link.approve(address(router), ccipFees);

        // https://ethereum.stackexchange.com/questions/156285/what-is-causing-arithmetic-over-underflow-when-link-transferfrom-is-called-for?newreg=509cdc7a0abe4e2a8a3a3d4aaf8cd8b8
        // link.approve(address(router), type(uint256).max);

        messageId = router.ccipSend(recipientChainId, ccipMessage);
        messageStack[messageId] = payload;
        emit MessageSent(recipient, payload.operation, payload.message);
    }

    /// @notice Allows the contract owner to withdraw the entire balance of Ether from the contract.
    /// @dev This function reverts if there are no funds to withdraw or if the transfer fails.
    /// It should only be callable by the owner of the contract.
    /// @param _beneficiary The address to which the Ether should be sent.
    function withdraw(address _beneficiary) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = address(this).balance;

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        // Attempt to send the funds, capturing the success status and discarding any return data
        (bool sent, ) = _beneficiary.call{value: amount}("");

        // Revert if the send failed, with information about the attempted transfer
        if (!sent) revert FailedToWithdrawEth(msg.sender, _beneficiary, amount);
    }

    /// @notice Allows the owner of the contract to withdraw all tokens of a specific ERC20 token.
    /// @dev This function reverts with a 'NothingToWithdraw' error if there are no tokens to withdraw.
    /// @param _beneficiary The address to which the tokens will be sent.
    /// @param _token The contract address of the ERC20 token to be withdrawn.
    function withdrawToken(
        address _beneficiary,
        address _token
    ) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = LinkTokenInterface(_token).balanceOf(address(this));
        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();
        LinkTokenInterface(_token).transfer(_beneficiary, amount);
    }
}
