// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;
/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */
/* solhint-disable no-empty-blocks */

import "../interfaces/IAccount.sol";
import "../interfaces/IAccountExecute.sol";
import "../interfaces/IEntryPoint.sol";
import "../interfaces/IPaymaster.sol";

import "../utils/Exec.sol";
import "./Helpers.sol";
import "./NonceManager.sol";
import "./SenderCreator.sol";
import "./StakeManager.sol";
import "./UserOperationLib.sol";
import "./Eip7702Support.sol";

import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/*
 * Account-Abstraction (EIP-4337) singleton EntryPoint implementation.
 * Only one instance required on each chain.
 */

/// @custom:security-contact https://bounty.ethereum.org
contract EntryPoint is IEntryPoint, StakeManager, NonceManager, ReentrancyGuardTransient, ERC165, EIP712 {

    using UserOperationLib for PackedUserOperation;

    SenderCreator private immutable _senderCreator = new SenderCreator();

    string constant internal DOMAIN_NAME = "ERC4337";
    string constant internal DOMAIN_VERSION = "1";

    constructor() EIP712(DOMAIN_NAME, DOMAIN_VERSION)  {
    }

    function senderCreator() public view virtual returns (ISenderCreator) {
        return _senderCreator;
    }

    //compensate for innerHandleOps' emit message and deposit refund.
    // allow some slack for future gas price changes.
    uint256 private constant INNER_GAS_OVERHEAD = 10000;

    // Marker for inner call revert on out of gas
    bytes32 private constant INNER_OUT_OF_GAS = hex"deaddead";
    bytes32 private constant INNER_REVERT_LOW_PREFUND = hex"deadaa51";

    uint256 private constant REVERT_REASON_MAX_LEN = 2048;
    // Penalty charged for either unused execution gas or postOp gas
    uint256 private constant UNUSED_GAS_PENALTY_PERCENT = 10;
    // Threshold below which no penalty would be charged
    uint256 private constant PENALTY_GAS_THRESHOLD = 40000;

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        // note: solidity "type(IEntryPoint).interfaceId" is without inherited methods but we want to check everything
        return interfaceId == (type(IEntryPoint).interfaceId ^ type(IStakeManager).interfaceId ^ type(INonceManager).interfaceId) ||
            interfaceId == type(IEntryPoint).interfaceId ||
            interfaceId == type(IStakeManager).interfaceId ||
            interfaceId == type(INonceManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * Compensate the caller's beneficiary address with the collected fees of all UserOperations.
     * @param beneficiary - The address to receive the fees.
     * @param amount      - Amount to transfer.
     */
    function _compensate(address payable beneficiary, uint256 amount) internal virtual {
        require(beneficiary != address(0), "AA90 invalid beneficiary");
        (bool success, ) = beneficiary.call{value: amount}("");
        require(success, "AA91 failed send to beneficiary");
    }

    /**
     * Execute a user operation.
     * @param opIndex    - Index into the opInfo array.
     * @param userOp     - The userOp to execute.
     * @param opInfo     - The opInfo filled by validatePrepayment for this userOp.
     * @return actualGasCost - The total amount this userOp paid.
     */
    function _executeUserOp(
        uint256 opIndex,
        PackedUserOperation calldata userOp,
        UserOpInfo memory opInfo
    )
    internal virtual
    returns (uint256 actualGasCost) {
        uint256 preGas = gasleft();
        bytes memory context = getMemoryBytesFromOffset(opInfo.contextOffset);
        bool innerSuccess;
        bytes32 returnData;
        uint256 actualGas;
        {
            uint256 saveFreePtr = getFreePtr();
            bytes calldata callData = userOp.callData;
            bytes memory innerCall;
            bytes4 methodSig;
            assembly {
                let len := callData.length
                if gt(len, 3) {
                    methodSig := calldataload(callData.offset)
                }
            }
            if (methodSig == IAccountExecute.executeUserOp.selector) {
                bytes memory executeUserOp = abi.encodeCall(IAccountExecute.executeUserOp, (userOp, opInfo.userOpHash));
                innerCall = abi.encodeCall(this.innerHandleOp, (executeUserOp, opInfo, context));
            } else
            {
                innerCall = abi.encodeCall(this.innerHandleOp, (callData, opInfo, context));
            }
            assembly ("memory-safe") {
                innerSuccess := call(gas(), address(), 0, add(innerCall, 0x20), mload(innerCall), 0, 64)
                returnData := mload(0)
                // returned by either INNER_REVERT_LOW_PREFUND or successful return.
                actualGas := mload(32)
            }
            restoreFreePtr(saveFreePtr);
        }
        bool executionSuccess;
        if (innerSuccess) {
            executionSuccess = returnData != 0;
        } else {
            bytes32 innerRevertCode = returnData;
            if (innerRevertCode == INNER_OUT_OF_GAS) {
                // handleOps was called with gas limit too low. abort entire bundle.
                // can only be caused by bundler (leaving not enough gas for inner call)
                revert FailedOp(opIndex, "AA95 out of gas");
            } else if (innerRevertCode != INNER_REVERT_LOW_PREFUND) {
                actualGas = preGas - gasleft();
                actualGas += _getUnusedGasPenalty(actualGas, opInfo.mUserOp.callGasLimit + opInfo.mUserOp.paymasterPostOpGasLimit);
                emit PostOpRevertReason(
                    opInfo.userOpHash,
                    opInfo.mUserOp.sender,
                    opInfo.mUserOp.nonce,
                    Exec.getReturnData(REVERT_REASON_MAX_LEN)
                );
            }
        }

        return _postInnerCall(
            opInfo,
            executionSuccess,
            actualGas,
            innerSuccess
        );
    }

    /**
     * Process the output of innerCall
     * - calculate paid gas.
     * - refund payer if needed.
     * - emit event of total cost exceeds prefund.
     * - emit UserOperationEvent
     * @param opInfo           - UserOp fields and info collected during validation.
     * @param executionSuccess - Whether account execution was successful.
     * @param actualGas        - actual gas used for execution and postOp
     * @param innerSuccess     - Whether inner call succeeded or reverted
     */
    function _postInnerCall(
        UserOpInfo memory opInfo,
        bool executionSuccess,
        uint256 actualGas,
        bool innerSuccess)
    internal virtual returns (uint256 collected) {
        unchecked {
            uint256 prefund = opInfo.prefund;
            uint256 actualGasCost = actualGas * getUserOpGasPrice(opInfo.mUserOp);
            uint256 refund;
            if (prefund >= actualGasCost) {
                refund = prefund - actualGasCost;
            } else {
                actualGasCost = prefund;
                //depending where the over-gas-used was found, we either reverted innerCall or not.
                emitPrefundTooLow(opInfo, !innerSuccess);
            }
            emitUserOperationEvent(opInfo, executionSuccess, actualGasCost, actualGas);
            _refundDeposit(opInfo, refund);
            return actualGasCost;
        }
    }

    /**
     * Emit the UserOperationEvent for the given UserOperation.
     *
     * @param opInfo         - The details of the current UserOperation.
     * @param success        - Whether the execution of the UserOperation has succeeded or not.
     * @param actualGasCost  - The actual cost of the consumed gas charged from the sender or the paymaster.
     * @param actualGas      - The actual amount of gas used.
     */
    function emitUserOperationEvent(UserOpInfo memory opInfo, bool success, uint256 actualGasCost, uint256 actualGas) internal virtual {
        emit UserOperationEvent(
            opInfo.userOpHash,
            opInfo.mUserOp.sender,
            opInfo.mUserOp.paymaster,
            opInfo.mUserOp.nonce,
            success,
            actualGasCost,
            actualGas
        );
    }

    /**
     * Emit the UserOperationPrefundTooLow event for the given UserOperation.
     *
     * @param opInfo - The details of the current UserOperation.
     */
    function emitPrefundTooLow(UserOpInfo memory opInfo, bool innerReverted) internal virtual {
        emit UserOperationPrefundTooLow(
            opInfo.userOpHash,
            opInfo.mUserOp.sender,
            opInfo.mUserOp.nonce,
            innerReverted
        );
    }

    /**
     * Iterate over calldata PackedUserOperation array and perform account and paymaster validation.
     * @notice UserOpInfo is a global array of all UserOps while PackedUserOperation is grouped per aggregator.
     *
     * @param ops - an array of UserOps to be validated
     * @param opInfos - an array of UserOp metadata being read and filled in during this function's execution
     * @param expectedAggregator - an address of the aggregator specified for a given UserOp if any, or address(0)
     * @param opIndexOffset - an offset for the index between 'ops' and 'opInfos' arrays, see the notice.
     * @return opsLen - processed UserOps (length of "ops" array)
     */
    function _iterateValidationPhase(
        PackedUserOperation[] calldata ops,
        UserOpInfo[] memory opInfos,
        address expectedAggregator,
        uint256 opIndexOffset
    ) internal returns(uint256 opsLen){
        unchecked {
            opsLen = ops.length;
            for (uint256 i = 0; i < opsLen; i++) {
                UserOpInfo memory opInfo = opInfos[opIndexOffset + i];
                (
                    uint256 validationData,
                    uint256 pmValidationData
                ) = _validatePrepayment(opIndexOffset + i, ops[i], opInfo);
                _validateAccountAndPaymasterValidationData(
                    opIndexOffset + i,
                    validationData,
                    pmValidationData,
                    expectedAggregator
                );
            }
        }
    }

    /// @inheritdoc IEntryPoint
    function handleOps(
        PackedUserOperation[] calldata ops,
        address payable beneficiary
    ) external nonReentrant {
        uint256 opslen = ops.length;
        UserOpInfo[] memory opInfos = new UserOpInfo[](opslen);
        unchecked {
            _iterateValidationPhase(ops, opInfos, address(0), 0);

            uint256 collected = 0;
            emit BeforeExecution();

            for (uint256 i = 0; i < opslen; i++) {
                collected += _executeUserOp(i, ops[i], opInfos[i]);
            }

            _compensate(beneficiary, collected);
        }
    }

    /// @inheritdoc IEntryPoint
    function handleAggregatedOps(
        UserOpsPerAggregator[] calldata opsPerAggregator,
        address payable beneficiary
    ) public nonReentrant {

        uint256 opasLen = opsPerAggregator.length;
        uint256 totalOps = 0;
        for (uint256 i = 0; i < opasLen; i++) {
            UserOpsPerAggregator calldata opa = opsPerAggregator[i];
            PackedUserOperation[] calldata ops = opa.userOps;
            IAggregator aggregator = opa.aggregator;

            //address(1) is special marker of "signature error"
            require(
                address(aggregator) != address(1),
                SignatureValidationFailed(address(aggregator))
            );

            if (address(aggregator) != address(0)) {
                try aggregator.validateSignatures(ops, opa.signature) {} catch {
                    revert SignatureValidationFailed(address(aggregator));
                }
            }

            totalOps += ops.length;
        }

        UserOpInfo[] memory opInfos = new UserOpInfo[](totalOps);

        uint256 opIndex = 0;
        for (uint256 a = 0; a < opasLen; a++) {
            UserOpsPerAggregator calldata opa = opsPerAggregator[a];
            PackedUserOperation[] calldata ops = opa.userOps;
            IAggregator aggregator = opa.aggregator;

            opIndex += _iterateValidationPhase(ops, opInfos, address(aggregator), opIndex);
        }

        emit BeforeExecution();

        uint256 collected = 0;
        opIndex = 0;
        for (uint256 a = 0; a < opasLen; a++) {
            UserOpsPerAggregator calldata opa = opsPerAggregator[a];
            emit SignatureAggregatorChanged(address(opa.aggregator));
            PackedUserOperation[] calldata ops = opa.userOps;
            uint256 opslen = ops.length;

            for (uint256 i = 0; i < opslen; i++) {
                collected += _executeUserOp(opIndex, ops[i], opInfos[opIndex]);
                opIndex++;
            }
        }
        emit SignatureAggregatorChanged(address(0));

        _compensate(beneficiary, collected);
    }

    /**
     * A memory copy of UserOp static fields only.
     * Excluding: callData, initCode and signature. Replacing paymasterAndData with paymaster.
     */
    struct MemoryUserOp {
        address sender;
        uint256 nonce;
        uint256 verificationGasLimit;
        uint256 callGasLimit;
        uint256 paymasterVerificationGasLimit;
        uint256 paymasterPostOpGasLimit;
        uint256 preVerificationGas;
        address paymaster;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
    }

    struct UserOpInfo {
        MemoryUserOp mUserOp;
        bytes32 userOpHash;
        uint256 prefund;
        uint256 contextOffset;
        uint256 preOpGas;
    }


    /**
     * Inner function to handle a UserOperation.
     * Must be declared "external" to open a call context, but it can only be called by handleOps.
     * @param callData - The callData to execute.
     * @param opInfo   - The UserOpInfo struct.
     * @param context  - The context bytes.
     * @return callSuccess - return status of sender callData
     * @return actualGasUsed - gas used by this call, including unused gas penalty
     */
    function innerHandleOp(
        bytes memory callData,
        UserOpInfo memory opInfo,
        bytes calldata context
    ) external returns (bool callSuccess, uint256 actualGasUsed) {
        uint256 preGas = gasleft();
        require(msg.sender == address(this), "AA92 internal call only");
        MemoryUserOp memory mUserOp = opInfo.mUserOp;

        uint256 callGasLimit = mUserOp.callGasLimit;
        unchecked {
            // handleOps was called with gas limit too low. abort entire bundle.
            if (
                gasleft() * 63 / 64 <
                callGasLimit +
                mUserOp.paymasterPostOpGasLimit +
                INNER_GAS_OVERHEAD
            ) {
                uint256 gasUsed = preGas - gasleft();
                assembly ("memory-safe") {
                    mstore(0, INNER_OUT_OF_GAS)
                    mstore(32, gasUsed)
                    revert(0, 64)
                }
            }
        }

        IPaymaster.PostOpMode mode = IPaymaster.PostOpMode.opSucceeded;
        if (callData.length > 0) {
            bool success = Exec.call(mUserOp.sender, 0, callData, callGasLimit);
            if (!success) {
                bytes memory result = Exec.getReturnData(REVERT_REASON_MAX_LEN);
                if (result.length > 0) {
                    emit UserOperationRevertReason(
                        opInfo.userOpHash,
                        mUserOp.sender,
                        mUserOp.nonce,
                        result
                    );
                }
                mode = IPaymaster.PostOpMode.opReverted;
            }
        }

        unchecked {
            uint256 executionGas = preGas - gasleft();
            uint256 actualGas = _postExecution(mode, opInfo, context, executionGas);
            return (mode == IPaymaster.PostOpMode.opSucceeded, actualGas);
        }
    }

    function getPackedUserOpTypeHash() public pure returns (bytes32) {
        return UserOperationLib.PACKED_USEROP_TYPEHASH;
    }

    function getDomainSeparatorV4() public virtual view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc IEntryPoint
    function getUserOpHash(
        PackedUserOperation calldata userOp
    ) public view returns (bytes32) {
        bytes32 overrideInitCodeHash = Eip7702Support._getEip7702InitCodeHashOverride(userOp);
        return
            MessageHashUtils.toTypedDataHash(getDomainSeparatorV4(), userOp.hash(overrideInitCodeHash));
    }

    /**
     * Copy general fields from userOp into the memory opInfo structure.
     * @param userOp  - The user operation.
     * @param mUserOp - The memory user operation.
     */
    function _copyUserOpToMemory(
        PackedUserOperation calldata userOp,
        MemoryUserOp memory mUserOp
    ) internal virtual pure {
        mUserOp.sender = userOp.sender;
        mUserOp.nonce = userOp.nonce;
        (mUserOp.verificationGasLimit, mUserOp.callGasLimit) = UserOperationLib.unpackUints(userOp.accountGasLimits);
        mUserOp.preVerificationGas = userOp.preVerificationGas;
        (mUserOp.maxPriorityFeePerGas, mUserOp.maxFeePerGas) = UserOperationLib.unpackUints(userOp.gasFees);
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        if (paymasterAndData.length > 0) {
            require(
                paymasterAndData.length >= UserOperationLib.PAYMASTER_DATA_OFFSET,
                "AA93 invalid paymasterAndData"
            );
            address paymaster;
            (paymaster, mUserOp.paymasterVerificationGasLimit, mUserOp.paymasterPostOpGasLimit) = UserOperationLib.unpackPaymasterStaticFields(paymasterAndData);
            require(paymaster != address(0), "AA98 invalid paymaster");
            mUserOp.paymaster = paymaster;
        }
    }

    /**
     * Get the required prefunded gas fee amount for an operation.
     * @param mUserOp - The user operation in memory.
     */
    function _getRequiredPrefund(
        MemoryUserOp memory mUserOp
    ) internal virtual pure returns (uint256 requiredPrefund) {
        unchecked {
            uint256 requiredGas = mUserOp.verificationGasLimit +
                mUserOp.callGasLimit +
                mUserOp.paymasterVerificationGasLimit +
                mUserOp.paymasterPostOpGasLimit +
                mUserOp.preVerificationGas;

            requiredPrefund = requiredGas * mUserOp.maxFeePerGas;
        }
    }

    /**
     * Create sender smart contract account if init code is provided.
     * @param opIndex  - The operation index.
     * @param opInfo   - The operation info.
     * @param initCode - The init code for the smart contract account.
     */
    function _createSenderIfNeeded(
        uint256 opIndex,
        UserOpInfo memory opInfo,
        bytes calldata initCode
    ) internal virtual {
        if (initCode.length != 0) {
            address sender = opInfo.mUserOp.sender;
            if ( Eip7702Support._isEip7702InitCode(initCode) ) {
                if (initCode.length>20 ) {
                    //already validated it is an EIP-7702 delegate (and hence, already has code)
                    senderCreator().initEip7702Sender(sender, initCode[20:]);
                }
                return;
            }
            if (sender.code.length != 0)
                revert FailedOp(opIndex, "AA10 sender already constructed");
            address sender1 = senderCreator().createSender{
                gas: opInfo.mUserOp.verificationGasLimit
            }(initCode);
            if (sender1 == address(0))
                revert FailedOp(opIndex, "AA13 initCode failed or OOG");
            if (sender1 != sender)
                revert FailedOp(opIndex, "AA14 initCode must return sender");
            if (sender1.code.length == 0)
                revert FailedOp(opIndex, "AA15 initCode must create sender");
            address factory = address(bytes20(initCode[0:20]));
            emit AccountDeployed(
                opInfo.userOpHash,
                sender,
                factory,
                opInfo.mUserOp.paymaster
            );
        }
    }

    /// @inheritdoc IEntryPoint
    function getSenderAddress(bytes calldata initCode) public {
        address sender = senderCreator().createSender(initCode);
        revert SenderAddressResult(sender);
    }

    /**
     * Call account.validateUserOp.
     * Revert (with FailedOp) in case validateUserOp reverts, or account didn't send required prefund.
     * Decrement account's deposit if needed.
     * @param opIndex         - The operation index.
     * @param op              - The user operation.
     * @param opInfo          - The operation info.
     * @param requiredPrefund - The required prefund amount.
     */
    function _validateAccountPrepayment(
        uint256 opIndex,
        PackedUserOperation calldata op,
        UserOpInfo memory opInfo,
        uint256 requiredPrefund
    )
        internal virtual
        returns (
            uint256 validationData
        )
    {
        unchecked {
            MemoryUserOp memory mUserOp = opInfo.mUserOp;
            address sender = mUserOp.sender;
            _createSenderIfNeeded(opIndex, opInfo, op.initCode);
            address paymaster = mUserOp.paymaster;
            uint256 missingAccountFunds = 0;
            if (paymaster == address(0)) {
                uint256 bal = balanceOf(sender);
                missingAccountFunds = bal > requiredPrefund
                    ? 0
                    : requiredPrefund - bal;
            }
            validationData = _callValidateUserOp(opIndex, op, opInfo, missingAccountFunds);
            if (paymaster == address(0)) {
                if (!_tryDecrementDeposit(sender, requiredPrefund)) {
                    revert FailedOp(opIndex, "AA21 didn't pay prefund");
                }
            }
        }
    }

    // call sender.validateUserOp()
    // handle wrong output size with FailedOp
    function _callValidateUserOp(
        uint256 opIndex,
        PackedUserOperation calldata op,
        UserOpInfo memory opInfo,
        uint256 missingAccountFunds
    )
    internal virtual returns (uint256 validationData) {
        uint256 gasLimit = opInfo.mUserOp.verificationGasLimit;
        address sender = opInfo.mUserOp.sender;
        bool success;
        {
            uint256 saveFreePtr = getFreePtr();
            bytes memory callData = abi.encodeCall(IAccount.validateUserOp, (op, opInfo.userOpHash, missingAccountFunds));
            assembly ("memory-safe"){
                success := call(gasLimit, sender, 0, add(callData, 0x20), mload(callData), 0, 32)
                validationData := mload(0)
                // any return data size other than 32 is considered failure
                if iszero(eq(returndatasize(), 32)) {
                    success := 0
                }
            }
            restoreFreePtr(saveFreePtr);
        }
        if (!success) {
            if(sender.code.length == 0) {
                revert FailedOp(opIndex, "AA20 account not deployed");
            } else {
                revert FailedOpWithRevert(opIndex, "AA23 reverted", Exec.getReturnData(REVERT_REASON_MAX_LEN));
            }
        }
    }

    /**
     * In case the request has a paymaster:
     *  - Validate paymaster has enough deposit.
     *  - Call paymaster.validatePaymasterUserOp.
     *  - Revert with proper FailedOp in case paymaster reverts.
     *  - Decrement paymaster's deposit.
     * @param opIndex                            - The operation index.
     * @param op                                 - The user operation.
     * @param opInfo                             - The operation info.
     * @param requiredPreFund                    - The required prefund amount.
     * @return context                           - The Paymaster-provided value to be passed to the 'postOp' function later
     * @return validationData                    - The Paymaster's validationData.
     */
    function _validatePaymasterPrepayment(
        uint256 opIndex,
        PackedUserOperation calldata op,
        UserOpInfo memory opInfo,
        uint256 requiredPreFund
    ) internal virtual returns (bytes memory context, uint256 validationData) {
        unchecked {
            uint256 preGas = gasleft();
            MemoryUserOp memory mUserOp = opInfo.mUserOp;
            address paymaster = mUserOp.paymaster;
            if (!_tryDecrementDeposit(paymaster, requiredPreFund)) {
                revert FailedOp(opIndex, "AA31 paymaster deposit too low");
            }
            uint256 pmVerificationGasLimit = mUserOp.paymasterVerificationGasLimit;
            try
                IPaymaster(paymaster).validatePaymasterUserOp{gas: pmVerificationGasLimit}(
                    op,
                    opInfo.userOpHash,
                    requiredPreFund
                )
            returns (bytes memory _context, uint256 _validationData) {
                context = _context;
                validationData = _validationData;
            } catch {
                revert FailedOpWithRevert(opIndex, "AA33 reverted", Exec.getReturnData(REVERT_REASON_MAX_LEN));
            }
            if (preGas - gasleft() > _getVerificationGasLimit(pmVerificationGasLimit)) {
                revert FailedOp(opIndex, "AA36 over paymasterVerificationGasLimit");
            }
        }
    }

    /**
     * Revert if either account validationData or paymaster validationData is expired.
     * @param opIndex                 - The operation index.
     * @param validationData          - The account validationData.
     * @param paymasterValidationData - The paymaster validationData.
     * @param expectedAggregator      - The expected aggregator.
     */
    function _validateAccountAndPaymasterValidationData(
        uint256 opIndex,
        uint256 validationData,
        uint256 paymasterValidationData,
        address expectedAggregator
    ) internal virtual view {
        (address aggregator, bool outOfTimeRange) = _getValidationData(
            validationData
        );
        if (expectedAggregator != aggregator) {
            revert FailedOp(opIndex, "AA24 signature error");
        }
        if (outOfTimeRange) {
            revert FailedOp(opIndex, "AA22 expired or not due");
        }
        // pmAggregator is not a real signature aggregator: we don't have logic to handle it as address.
        // Non-zero address means that the paymaster fails due to some signature check (which is ok only during estimation).
        address pmAggregator;
        (pmAggregator, outOfTimeRange) = _getValidationData(
            paymasterValidationData
        );
        if (pmAggregator != address(0)) {
            revert FailedOp(opIndex, "AA34 signature error");
        }
        if (outOfTimeRange) {
            revert FailedOp(opIndex, "AA32 paymaster expired or not due");
        }
    }

    /**
     * Parse validationData into its components.
     * @param validationData - The packed validation data (sigFailed, validAfter, validUntil).
     * @return aggregator the aggregator of the validationData
     * @return outOfTimeRange true if current time is outside the time range of this validationData.
     */
    function _getValidationData(
        uint256 validationData
    ) internal virtual view returns (address aggregator, bool outOfTimeRange) {
        if (validationData == 0) {
            return (address(0), false);
        }
        ValidationData memory data = _parseValidationData(validationData);
        // solhint-disable-next-line not-rely-on-time
        outOfTimeRange = block.timestamp > data.validUntil || block.timestamp <= data.validAfter;
        aggregator = data.aggregator;
    }

    /**
     * Validate account and paymaster (if defined) and
     * also make sure total validation doesn't exceed verificationGasLimit.
     * This method is called off-chain (simulateValidation()) and on-chain (from handleOps)
     * @param opIndex    - The index of this userOp into the "opInfos" array.
     * @param userOp     - The packed calldata UserOperation structure to validate.
     * @param outOpInfo  - The empty unpacked in-memory UserOperation structure that will be filled in here.
     *
     * @return validationData          - The account's validationData.
     * @return paymasterValidationData - The paymaster's validationData.
     */
    function _validatePrepayment(
        uint256 opIndex,
        PackedUserOperation calldata userOp,
        UserOpInfo memory outOpInfo
    )
        internal virtual
        returns (uint256 validationData, uint256 paymasterValidationData)
    {
        uint256 preGas = gasleft();
        MemoryUserOp memory mUserOp = outOpInfo.mUserOp;
        _copyUserOpToMemory(userOp, mUserOp);
        outOpInfo.userOpHash = getUserOpHash(userOp);

        // Validate all numeric values in userOp are well below 128 bit, so they can safely be added
        // and multiplied without causing overflow.
        uint256 verificationGasLimit = mUserOp.verificationGasLimit;
        uint256 maxGasValues = mUserOp.preVerificationGas |
            verificationGasLimit |
            mUserOp.callGasLimit |
            mUserOp.paymasterVerificationGasLimit |
            mUserOp.paymasterPostOpGasLimit |
            mUserOp.maxFeePerGas |
            mUserOp.maxPriorityFeePerGas;
        require(maxGasValues <= type(uint120).max, FailedOp(opIndex, "AA94 gas values overflow"));

        uint256 requiredPreFund = _getRequiredPrefund(mUserOp);
        validationData = _validateAccountPrepayment(
            opIndex,
            userOp,
            outOpInfo,
            requiredPreFund
        );

        require(
            _validateAndUpdateNonce(mUserOp.sender, mUserOp.nonce),
            FailedOp(opIndex, "AA25 invalid account nonce")
        );

        unchecked {
            if (preGas - gasleft() > _getVerificationGasLimit(verificationGasLimit)) {
                revert FailedOp(opIndex, "AA26 over verificationGasLimit");
            }
        }

        bytes memory context;
        if (mUserOp.paymaster != address(0)) {
            (context, paymasterValidationData) = _validatePaymasterPrepayment(
                opIndex,
                userOp,
                outOpInfo,
                requiredPreFund
            );
        }
        unchecked {
            outOpInfo.prefund = requiredPreFund;
            outOpInfo.contextOffset = getOffsetOfMemoryBytes(context);
            outOpInfo.preOpGas = preGas - gasleft() + userOp.preVerificationGas;
        }
    }

    // return verification gas limit.
    // This method is overridden in EntryPointSimulations, for slightly stricter gas limits.
    function _getVerificationGasLimit(uint256 verificationGasLimit) internal pure virtual returns (uint256) {
        return verificationGasLimit;
    }

    /**
     * Process post-operation, called just after the callData is executed.
     * If a paymaster is defined and its validation returned a non-empty context, its postOp is called.
     * The excess amount is refunded to the account (or paymaster - if it was used in the request).
     * @param mode      - Whether is called from innerHandleOp, or outside (postOpReverted).
     * @param opInfo    - UserOp fields and info collected during validation.
     * @param context   - The context returned in validatePaymasterUserOp.
     * @param executionGas - The gas used for execution of this user operation.
     */
    function _postExecution(
        IPaymaster.PostOpMode mode,
        UserOpInfo memory opInfo,
        bytes calldata context,
        uint256 executionGas
    ) internal virtual returns (uint256 actualGas) {
        uint256 preGas = gasleft();
        unchecked {
            MemoryUserOp memory mUserOp = opInfo.mUserOp;
            uint256 gasPrice = getUserOpGasPrice(mUserOp);

            // Calculating a penalty for unused execution gas
            actualGas = executionGas + _getUnusedGasPenalty(executionGas, mUserOp.callGasLimit) + opInfo.preOpGas;
            if (context.length > 0) {
                uint postOpUnusedGasPenalty = _callPostOp(mUserOp, mode, context, actualGas, gasPrice);
                actualGas += postOpUnusedGasPenalty;
            }
            actualGas += preGas - gasleft();
            uint256 actualGasCost = actualGas * gasPrice;
            if (opInfo.prefund < actualGasCost) {
                assembly ("memory-safe") {
                    mstore(0, INNER_REVERT_LOW_PREFUND)
                    mstore(32, actualGas)
                    revert(0, 64)
                }
            }
        } // unchecked
    }

    function _callPostOp(
        MemoryUserOp memory mUserOp,
        IPaymaster.PostOpMode mode,
        bytes calldata context,
        uint256 actualGas,
        uint256 gasPrice )
    internal virtual returns (uint256 postOpUnusedGasPenalty) {

        uint256 postOpPreGas = gasleft();
        uint256 actualGasCostForPostOp = actualGas * gasPrice;
        try IPaymaster(mUserOp.paymaster).postOp{
                gas: mUserOp.paymasterPostOpGasLimit
            }(mode, context, actualGasCostForPostOp, gasPrice)
        {} catch {
            bytes memory reason = Exec.getReturnData(REVERT_REASON_MAX_LEN);
            revert PostOpReverted(reason);
        }
        // Calculating a penalty for unused postOp gas
        uint256 postOpGasUsed = postOpPreGas - gasleft();
        postOpUnusedGasPenalty = _getUnusedGasPenalty(postOpGasUsed, mUserOp.paymasterPostOpGasLimit);
    }

    function _refundDeposit(UserOpInfo memory opInfo, uint256 refundAmount) internal virtual {
        address refundAddress = opInfo.mUserOp.paymaster;
        if (refundAddress == address(0)) {
            refundAddress = opInfo.mUserOp.sender;
        }
        _incrementDeposit(refundAddress, refundAmount);
    }

    /**
     * The gas price this UserOp agrees to pay.
     * Relayer/block builder might submit the TX with higher priorityFee, but the user should not be affected.
     * @param mUserOp - The userOp to get the gas price from.
     */
    function getUserOpGasPrice(
        MemoryUserOp memory mUserOp
    ) internal view returns (uint256) {
        unchecked {
            uint256 maxFeePerGas = mUserOp.maxFeePerGas;
            uint256 maxPriorityFeePerGas = mUserOp.maxPriorityFeePerGas;
            if (maxFeePerGas == maxPriorityFeePerGas) {
                //legacy mode (for networks that don't support basefee opcode)
                return maxFeePerGas;
            }
            return min(maxFeePerGas, maxPriorityFeePerGas + block.basefee);
        }
    }

    /// @inheritdoc IEntryPoint
    function delegateAndRevert(address target, bytes calldata data) external {
        (bool success, bytes memory ret) = target.delegatecall(data);
        revert DelegateAndRevert(success, ret);
    }

    /**
     * The offset of the given bytes in memory.
     * @param data - The bytes to get the offset of.
     */
    function getOffsetOfMemoryBytes(
        bytes memory data
    ) internal pure returns (uint256 offset) {
        assembly {
            offset := data
        }
    }

    /**
     * The bytes in memory at the given offset.
     * @param offset - The offset to get the bytes from.
     */
    function getMemoryBytesFromOffset(
        uint256 offset
    ) internal pure returns (bytes memory data) {
        assembly ("memory-safe") {
            data := offset
        }
    }

    /**
     * save free memory pointer.
     * save "free memory" pointer, so that it can be restored later using restoreFreePtr.
     * This reduce unneeded memory expansion, and reduce memory expansion cost.
     * NOTE: all dynamic allocations between saveFreePtr and restoreFreePtr MUST NOT be used after restoreFreePtr is called.
     */
    function getFreePtr() internal pure returns (uint256 ptr) {
        assembly ("memory-safe") {
            ptr := mload(0x40)
        }
    }

    /**
     * restore free memory pointer.
     * any allocated memory since saveFreePtr is cleared, and MUST NOT be accessed later.
     */
    function restoreFreePtr(uint256 ptr) internal pure {
        assembly ("memory-safe") {
            mstore(0x40, ptr)
        }
    }

    function _getUnusedGasPenalty(uint256 gasUsed, uint256 gasLimit) internal pure returns (uint256) {
        unchecked {
            if (gasLimit <= gasUsed + PENALTY_GAS_THRESHOLD) {
                return 0;
            }
            uint256 unusedGas = gasLimit - gasUsed;
            uint256 unusedGasPenalty = (unusedGas * UNUSED_GAS_PENALTY_PERCENT) / 100;
            return unusedGasPenalty;
        }
    }
}
