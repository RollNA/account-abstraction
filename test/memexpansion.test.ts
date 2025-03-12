
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
const maxUserOpSize = 8192
const contextLength = 2048
const preAllocatedMemory = 65536

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
    const methodsig = '0xb0d691fe' // entryPoint(). do-nothing function.
    const op = await fillAndSign({
      sender: simpleAccount.address,
      nonce: uniqueNonce(),
      // callData,
      callGasLimit: cgl,
      paymaster: pmVgl > 0 ? paymaster.address : undefined,
      paymasterVerificationGasLimit: pmVgl > 0 ? pmVgl : undefined,
      paymasterPostOpGasLimit: pmVgl > 0 ? 100000 : undefined,
      paymasterData: pmVgl > 0 ? hexZeroPad(hexlify(contextLen), 4) : undefined,
      maxFeePerGas,
      maxPriorityFeePerGas,
      verificationGasLimit: vgl,
      callData: methodsig.padEnd(userOpSize * 2, '0')
    }, accountOwner, entryPoint)
    // console.log('userop=', userOpSize)
    return op
  }

  async function callEntryPointWithMem (offsetSlot: number): Promise<CallHandleOpFunc> {
    const beneficiary = createAddress()
    const wasteMemoryUserOp = await createUserOpWithGas(100000, 1e6, offsetSlot)
    const callHandleOps = async (op: UserOperation): Promise<ContractReceipt> => {
      const ops = [wasteMemoryUserOp, op]
      const rcpt = await entryPoint.handleOps(ops.map(packUserOp), beneficiary, { gasLimit: 1000000 })
        .then(async r => r.wait())
      // remove the UserOperationEvent of the first (wasted) op. findMin need to process the one of our op.
      const userOpEvents = rcpt.events?.filter(e => e.event === 'UserOperationEvent')
      if (userOpEvents?.length === 2) {
        userOpEvents[0].event = 'Ignored-UserOperationEvent'
      }
      return rcpt
    }
    return callHandleOps
  }
  [1, maxUserOpSize / 2, maxUserOpSize].forEach(userOpSize => {
    [1, 2000].forEach(contextSize => {
      it(`check with userop ${userOpSize} and context ${contextSize}`, async () => {
        const res: any = []
        for (const wasteMemory of [1, preAllocatedMemory]) {
          const vgl = await findUserOpWithMin1(async n => createUserOpWithGas(n, 100000, contextLength, 0, userOpSize), false,
            await callEntryPointWithMem(wasteMemory), 10, 100000)
          const pmvgl = await findUserOpWithMin1(async n => createUserOpWithGas(vgl, n, contextLength, 0, userOpSize), false,
            await callEntryPointWithMem(wasteMemory), 10, 100000)
          const callGas = await findUserOpWithMin1(async n => createUserOpWithGas(vgl, pmvgl, contextLength, n, userOpSize), true,
            await callEntryPointWithMem(wasteMemory), 10, 100000)
          // console.log(`waste (before userop)=${wasteMemory}\tuserOpSize=${userOpSize}\tcontextSize=${contextSize}\tvgl=${vgl}, pmvgl=${pmvgl} cgl=${callGas}`)
          res.push({ vgl, pmvgl, callGas })
        }
        console.log(`waste effect on userop ${userOpSize} with context ${contextSize}:`,
              `vgl=${res[1].vgl - res[0].vgl}`,
                `pmvgl=${res[1].pmvgl - res[0].pmvgl}`,
                `cgl=${res[1].callGas - res[0].callGas}`)
      })
    })
  })
})
