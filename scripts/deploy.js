/**
 * Pot deployment script (Hardhat).
 *
 * Deploys the three-contract system in dependency order and wires up the
 * ownership invariant that lets the factory authorize pools:
 *
 *   1. Deploy PotScore (deployer is initial owner).
 *   2. Deploy PotFactory, pointing it at PotScore + the protocol treasury.
 *   3. Transfer ownership of PotScore to the factory, so that every
 *      `factory.createPool(...)` can call `scoreContract.authorizePool(pool)`.
 *
 * Usage:
 *   npx hardhat run scripts/deploy.js --network baseSepolia
 *
 * Required env:
 *   DEPLOYER_PRIVATE_KEY, and a PROTOCOL_TREASURY address.
 */

const hre = require("hardhat");

async function main() {
  const treasury = process.env.PROTOCOL_TREASURY;
  if (!treasury) {
    throw new Error("Set PROTOCOL_TREASURY to the address that collects the 1% protocol fee.");
  }

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Network:", hre.network.name);

  // 1. PotScore — soulbound reputation registry.
  const PotScore = await hre.ethers.getContractFactory("PotScore");
  const score = await PotScore.deploy();
  await score.waitForDeployment();
  const scoreAddr = await score.getAddress();
  console.log("PotScore deployed:", scoreAddr);

  // 2. PotFactory — pool deployer + index.
  const PotFactory = await hre.ethers.getContractFactory("PotFactory");
  const factory = await PotFactory.deploy(scoreAddr, treasury);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("PotFactory deployed:", factoryAddr);

  // 3. Transfer PotScore ownership to the factory so createPool() can authorize pools.
  const tx = await score.transferOwnership(factoryAddr);
  await tx.wait();
  console.log("PotScore ownership transferred to factory.");

  console.log("\nDeployment complete:");
  console.log("  PotScore   :", scoreAddr);
  console.log("  PotFactory :", factoryAddr);
  console.log("  Treasury   :", treasury);
  console.log("\nVerify with:");
  console.log(`  npx hardhat verify --network ${hre.network.name} ${scoreAddr}`);
  console.log(
    `  npx hardhat verify --network ${hre.network.name} ${factoryAddr} ${scoreAddr} ${treasury}`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
