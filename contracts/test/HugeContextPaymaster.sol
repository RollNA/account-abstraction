// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {IAccount} from "../interfaces/IAccount.sol";
import "../interfaces/IPaymaster.sol";
/* solhint-disable no-empty-blocks */

// dummy account. doesn't even pay, as it is used with the paymaster below
contract DummyAccount is IAccount {
    function validateUserOp(PackedUserOperation calldata, bytes32, uint256)
    external returns (uint256 validationData) {
        return 0;
    }
}

/**
 * test paymaster, that pays for everything, without any check.
 * explicitly returns a huge context.
 */
contract HugeContextPaymaster is IPaymaster {

    uint contextSize;
    constructor(uint _contextSize) {
        contextSize = _contextSize;
    }

    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
    external returns (bytes memory context, uint256 validationData) {
        return (new bytes(contextSize), 0);
    }

    function postOp(PostOpMode, bytes calldata context, uint256, uint256) external {
        (context);
    }
}
