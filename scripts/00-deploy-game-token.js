const { network } = require("hardhat")
const { VERIFICATION_BLOCK_CONFIRMATIONS, developmentChains } = require("../helper-hardhat-config")
const { verify } = require("../helper-functions")

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy, log } = deployments
    const { deployer } = await getNamedAccounts()
    const waitBlockConfirmations = developmentChains.includes(network.name)
        ? 1
        : VERIFICATION_BLOCK_CONFIRMATIONS
    log("----------------------------------------------------")
    const args = []
    const gameToken = await deploy("GameToken", {
        from: deployer,
        args: args,
        log: true,
        waitConfirmations: waitBlockConfirmations,
    })

    // Verify the deployment
    if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
        log("Verifying...")
        await verify(gameToken.address, args)
    }
    log("----------------------------------------------------")
}

module.exports.tags = ["all", "gametoken"]

// Remix 0x98D150DcE12732Be96f349D1BAB5c0B16152Ed6F

// Deploying contracts with the account: 0x19Fd1450F65c49e485246a679FFef12F73d4918e
// Game contract deployed:  0xc9810568346c8d5C1274bf6eb2b9Cb9295BaD19E

