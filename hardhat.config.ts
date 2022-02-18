import '@nomiclabs/hardhat-ethers';
import '@typechain/hardhat';

const config = {
  solidity: {
    version: '0.8.9',
    settings: {
      outputSelection: {
        '*': {
          '*': ['storageLayout'],
        },
      },
      optimizer: {
        enabled: true,
        runs: 10000,
      },
    },
  },
};

export default config;
