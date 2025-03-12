
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

  async function createUserOpWithGas (vgl: BigNumberish, pmVgl: number, contextLen = 1, cgl = 0, userOpSize = 0): Promise<UserOperation> {
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
  [1, useropsize].forEach(userOpSize => {
    [1, wasteMemory].forEach(wasteMemory => {
      [1, 2000].forEach(contextSize => {
        it(`check with wasted memory ${wasteMemory} and context ${contextSize}`, async () => {
          const vgl = await findUserOpWithMin1(async n => createUserOpWithGas(n, 100000, contextLength, userOpSize), false,
            await callEntryPointWithMem(wasteMemory), 10, 100000)
          const pmvgl = await findUserOpWithMin1(async n => createUserOpWithGas(vgl, n, contextLength, userOpSize), false,
            await callEntryPointWithMem(wasteMemory), 10, 100000)
          console.log(`userppsize=${userOpSize}\twaste=${wasteMemory}\tcontextSize=${contextSize}\tvgl=${vgl}, pmvgl=${pmvgl}`)
        })
      })
    })
  })
})
