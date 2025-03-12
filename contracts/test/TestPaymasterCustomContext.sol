pragma solidity ^0.8.4;

import "./TestPaymasterAcceptAll.sol";
// SPDX-License-Identifier: GPL-3.0


contract TestPaymasterCustomContext is TestPaymasterAcceptAll {
    event PostOpActualGasCost(uint256 actualGasCost, bytes context, bool isSame);

    constructor(IEntryPoint _entryPoint) TestPaymasterAcceptAll(_entryPoint) {
    }

    //paymasterData contains 4-byte length field of the context
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256)
    internal virtual override view
    returns (bytes memory context, uint256 validationData) {
        // context length is in paymasterAndData
        uint256 contextLength = uint32(bytes4(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET :]));
        return (new bytes(contextLength), SIG_VALIDATION_SUCCESS);
    }

    function _postOp(PostOpMode, bytes calldata context, uint256 actualGasCost, uint256)
    internal pure override {
        (context, actualGasCost);
        if (context.length<10000) {
            while (true) {
                //waste gas...
            }
        }
        require( context.length>10000, "revert postop");
    }
}
