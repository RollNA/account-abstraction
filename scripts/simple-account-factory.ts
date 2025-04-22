import { ethers } from 'hardhat'

// eslint-disable-next-line @typescript-eslint/explicit-function-return-type
async function main () {
  const ContractAFactory = await ethers.getContractFactory('SimpleAccountFactory')

  const constructorArgs: [string] = ['0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789']

  const deployTx = ContractAFactory.getDeployTransaction(...constructorArgs)
  const initCode = deployTx.data!

  console.log('Init Code:', initCode)
  const salt = ethers.utils.id('Goose V3 Account')
  // 0x1b110a3e6bc28a060bafdd818e9c1f702b5c33831e9353ef46ccb678095bf130
  console.log('Salt', salt)
  const initCodeHash = ethers.utils.keccak256(initCode)
  const predictedAddress = ethers.utils.getCreate2Address('0xce0042B868300000d44A59004Da54A005ffdcf9f', salt, initCodeHash)
  console.log('predictedAddress:', predictedAddress)
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
