require("@nomicfoundation/hardhat-toolbox");

/**
 * Hardhat configuration for the Pot contracts.
 *
 * Environment variables (set in a local .env, never committed):
 *   DEPLOYER_PRIVATE_KEY  - hex private key for the deploying account
 *   BASESCAN_API_KEY      - for contract verification on Basescan
 *   BASE_RPC_URL          - optional override for Base mainnet RPC
 *   BASE_SEPOLIA_RPC_URL  - optional override for Base Sepolia RPC
 *
 * Networks:
 *   baseSepolia (84532)  - testnet, use this for all development
 *   base        (8453)   - mainnet, do NOT deploy here without an audit
 */

const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || "";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      // viaIR helps with the stack depth in PotPool's lifecycle methods.
      viaIR: true,
      // Base is post-Cancun; pin it explicitly so dependency code that emits
      // `mcopy` (OZ v5, Chainlink) compiles. Must match foundry.toml's evm_version.
      evmVersion: "cancun",
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org",
      chainId: 84532,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : [],
    },
    base: {
      url: process.env.BASE_RPC_URL || "https://mainnet.base.org",
      chainId: 8453,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    apiKey: {
      base: process.env.BASESCAN_API_KEY || "",
      baseSepolia: process.env.BASESCAN_API_KEY || "",
    },
    customChains: [
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
    ],
  },
};
