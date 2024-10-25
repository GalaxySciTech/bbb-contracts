const { VoidSigner } = require("ethers");

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
      xdcparentnet: "test",
      xdc: "GUW8GTEK3UTC9RDW5XAXHHI3H5R9E69Y12",
    },
    customChains: [
      {
        network: "xdc",
        chainId: 50,
        urls: {
          apiURL: "https://api.xdcscan.com/api",
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
