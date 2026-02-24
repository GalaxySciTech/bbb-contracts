const { VoidSigner } = require("ethers");
const { SocksProxyAgent } = require("socks-proxy-agent");

require("@nomiclabs/hardhat-waffle");
require("hardhat-gas-reporter");
require("@nomicfoundation/hardhat-verify");
require("dotenv").config();
const network = require("./network.config.json");

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    version: "0.8.23",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  networks: {
    eth: {
      url: `https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
      accounts: [
        process.env.PRIVATE_KEY ||
          "1234567890123456789012345678901234567890123456789012345678901234",
      ],
    },
    xdcparentnet: {
      url: network["xdcparentnet"],
      accounts: [
        process.env.PRIVATE_KEY ||
          "1234567890123456789012345678901234567890123456789012345678901234",
      ],
    },
    xdcsubnet: {
      url: network["xdcsubnet"],
      accounts: [
        process.env.PRIVATE_KEY ||
          "1234567890123456789012345678901234567890123456789012345678901234",
      ],
    },
    xdc: {
      url: network["xdc"],
      accounts: [
        process.env.PRIVATE_KEY ||
          "1234567890123456789012345678901234567890123456789012345678901234",
      ],
    },
    xdctestnet: {
      url: network["xdctestnet"],
      accounts: [
        process.env.PRIVATE_KEY ||
          "1234567890123456789012345678901234567890123456789012345678901234",
      ],
    },
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY,
      xdcparentnet: "test",
      xdc: process.env.ETHERSCAN_API_KEY,
    },
    customChains: [
      {
        network: "xdc",
        chainId: 50,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=50",
          browserURL: "https://xdcscan.com/",
        },
      },
      {
        network: "xdcparentnet",
        chainId: 551,
        urls: {
          apiURL: "https://devnetapi.blocksscan.io/api",
          browserURL: "https://devnet.blocksscan.io/",
        },
      },
    ],
  },
};
