
/**
 * test for memory expansion.
 * given a set of parameters, create a bundle with worst-case userops.
 * memory expansion has 2 implications:
 * 1. validation of first userop is cheaper.
 *      the mitigation (in validation rules) is to require validatiokn to have a slack.
 * 2. execution of all userops in a batch is more expensive than when checked alone.
 *      the cost of execution overhead (calling into innerHandleOp) has to be done through
 *      the preVerificationGas.
 *
 * causes of memory expansion:
 * - total # of UserOps in a bundle (a userop is checked in a bundle of size 1, so there
 *  are no previous UserOps to cause
 */
import {
  CallHandleOpFunc,
  createAccount,
  createAccountOwner,
  createAddress,
  deployEntryPoint,
  findUserOpWithMin1,
  fund
} from './testutils'
import { ethers } from 'hardhat'
import { EntryPoint, SimpleAccount, TestPaymasterCustomContext, TestPaymasterCustomContext__factory } from '../typechain'
import { fillAndSign, packUserOp } from './UserOp'
import { UserOperation } from './UserOperation'
import { BigNumber, BigNumberish, ContractReceipt } from 'ethers'
import { hexlify, hexZeroPad } from 'ethers/lib/utils'

/**
 * build userop with default params, but after the given slot
 * @param slot
 */
const useropsize = 8192
const contextLength = 2048
const wasteMemory = 65536

describe('Memory expansion tests', function () {
  let entryPoint: EntryPoint
  const ethersSigner = ethers.provider.getSigner()
  const accountOwner = createAccountOwner()
  let simpleAccount: SimpleAccount
  let paymaster: TestPaymasterCustomContext
  const maxFeePerGas = 1
  const maxPriorityFeePerGas = 1

  before(async () => {
    entryPoint = await deployEntryPoint();
    ({
      proxy: simpleAccount
    } = await createAccount(ethersSigner, await accountOwner.getAddress(), entryPoint.address))
    await fund(simpleAccount.address)

    paymaster = await new TestPaymasterCustomContext__factory(ethersSigner).deploy(entryPoint.address)
    await entryPoint.depositTo(paymaster.address, { value: ethers.utils.parseEther('1') })
  })

  let nonceKey: number = 1
  // since we're reusing same account, make sure all our nonces are unique
  // (NOTE: it does take gas for storage, and offset the warm access to this account used over)
  function uniqueNonce (): BigNumber {
    return BigNumber.from(nonceKey++).shl(128)
  }

  async function createUserOpWithGas (vgl: BigNumberish, pmVgl: number, contextLen = 1, cgl = 0, callData = '0x'): Promise<UserOperation> {
    const methodsig = '0x3b6a02f6' // wasteGas()
    return fillAndSign({
      sender: simpleAccount.address,
      nonce: uniqueNonce(),
      // callData,
      callGasLimit: cgl,
      paymaster: pmVgl > 0 ? paymaster.address : undefined,
      paymasterVerificationGasLimit: pmVgl > 0 ? pmVgl : undefined,
      paymasterData: pmVgl > 0 ? hexZeroPad(hexlify(contextLen), 4) : undefined,
      maxFeePerGas,
      maxPriorityFeePerGas,
      verificationGasLimit: vgl,
      callData: methodsig.padEnd(useropsize * 2, '0')
    }, accountOwner, entryPoint)
  }

  async function callEntryPointWithMem (offsetSlot: number): Promise<CallHandleOpFunc> {
    const beneficiary = createAddress()
    const wasteMemoryUserOp = await createUserOpWithGas(100000, 1e6, offsetSlot)
    const callHandleOps = async (op: UserOperation): Promise<ContractReceipt> => {
      const ops = [wasteMemoryUserOp, op]
      return entryPoint.handleOps(ops.map(packUserOp), beneficiary, { gasLimit: 1000000 })
        .then(async r => r.wait())
    }
    return callHandleOps
  }
  it('should validate and check it supports memory expansion', async () => {
    console.log('================= 0 =====================')
    const vgl0 = await findUserOpWithMin1(async n => createUserOpWithGas(n, 100000, contextLength), false,
      await callEntryPointWithMem(1), 10, 100000)
    const pmvgl0 = await findUserOpWithMin1(async n => createUserOpWithGas(vgl0, n, contextLength), false,
      await callEntryPointWithMem(1), 10, 100000)
    console.log('================= 100000 =====================')
    const vgl2 = await findUserOpWithMin1(async n => createUserOpWithGas(n, 100000, contextLength), false,
      await callEntryPointWithMem(wasteMemory), 10, 100000)
    const pmvgl2 = await findUserOpWithMin1(async n => createUserOpWithGas(vgl2, n, contextLength), false,
      await callEntryPointWithMem(wasteMemory), 10, 100000)
    console.log('vgl0', vgl0, pmvgl0, 'vgl2', vgl2, pmvgl2, 'diff=', vgl2 - vgl0, pmvgl2 - pmvgl0)
  })
})
