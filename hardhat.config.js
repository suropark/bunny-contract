require('dotenv').config();
require('@nomiclabs/hardhat-ethers');
require('@openzeppelin/hardhat-upgrades');
require('@nomiclabs/hardhat-etherscan');
const PRIVATE_KEY = process.env.PRIVATE_KEY;

module.exports = {
  solidity: {
    version: '0.6.12',
    settings: {
      // evmVersion: 'istanbul',
      optimizer: {
        enabled: true,
        runs: 999999,
      },
    },
  },
  etherscan: {
    apiKey: process.env.POLYGONSCAN_API_KEY,
  },
  // npx hardhat verify --constructor-args .\verify.js --network mumbai  0x3850DdEB93c6C7103B5625a7B14047aDE7Ff8D98
  networks: {
    polygon: {
      url: 'https://polygon-rpc.com/',
      chainId: 137,
      accounts: [PRIVATE_KEY],
    },
    mumbai: {
      url: 'https://rpc-mumbai.matic.today',
      chainId: 80001,
      accounts: [PRIVATE_KEY],
    },
  },
};
