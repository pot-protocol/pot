/**
 * Pot deployment script (Hardhat).
 *
 * Deploys the three-contract system in dependency order and wires up the
 * ownership invariant that lets the factory authorize pools:
 *
 *   1. Deploy PotScore (deployer is initial owner).
 *   2. Deploy PotFactory, pointing it at PotScore + the protocol treasury and
 *      the Chainlink VRF v2.5 coordinator/config. The factory creates its OWN
 *      VRF subscription in its constructor and becomes the subscription owner.
 *   3. Transfer ownership of PotScore to the factory, so that every
 *      `factory.createPool(...)` can call `scoreContract.authorizePool(pool)`
 *      and `coordinator.addConsumer(subId, pool)`.
 *   4. Fund the factory's VRF subscription (manual step, printed below) so pools
 *      can actually be started. At PROTOCOL_FEE_BPS = 0 the protocol/treasury
 *      subsidizes VRF, which preserves the "put in $X, get back $X" promise.
 *
 * Usage:
 *   npx hardhat run scripts/deploy.js --network baseSepolia
 *
 * Required env:
 *   DEPLOYER_PRIVATE_KEY, PROTOCOL_TREASURY.
 * Optional env (override the per-network defaults below):
 *   VRF_COORDINATOR, VRF_KEY_HASH, VRF_CALLBACK_GAS_LIMIT,
 *   VRF_REQUEST_CONFIRMATIONS, VRF_NATIVE_PAYMENT ("true"/"false").
 */

const hre = require("hardhat");

// Chainlink VRF v2.5 per-network config.
// VERIFY THESE against https://docs.chain.link/vrf/v2-5/supported-networks
// before any mainnet deploy — coordinator addresses and key hashes can change.
const VRF = {
  baseSepolia: {
    coordinator: "0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE",
    keyHash: "0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71", // 30 gwei
    link: "0xE4aB69C077896252FAFBD49EFD26B5D171A32410",
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", // Circle USDC on Base Sepolia — VERIFY before use
  },
  base: {
    coordinator: "0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634",
    keyHash: "0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70", // 30 gwei
    link: "0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", // Circle USDC on Base mainnet
  },
};

async function main() {
  const treasury = process.env.PROTOCOL_TREASURY;
  if (!treasury) {
    throw new Error("Set PROTOCOL_TREASURY to the protocol treasury address.");
  }

  const net = hre.network.name;
  const defaults = VRF[net];
  if (!defaults && !process.env.VRF_COORDINATOR) {
    throw new Error(
      `No VRF config for network "${net}". Set VRF_COORDINATOR / VRF_KEY_HASH env vars, ` +
        `or add this network to the VRF map in scripts/deploy.js.`
    );
  }

  const coordinator = process.env.VRF_COORDINATOR || defaults.coordinator;
  const keyHash = process.env.VRF_KEY_HASH || defaults.keyHash;
  const callbackGasLimit = Number(process.env.VRF_CALLBACK_GAS_LIMIT || 1_500_000);
  const requestConfirmations = Number(process.env.VRF_REQUEST_CONFIRMATIONS || 3);
  const nativePayment = (process.env.VRF_NATIVE_PAYMENT || "true").toLowerCase() === "true";
  const usdc = process.env.USDC_ADDRESS || (defaults && defaults.usdc);
  if (!usdc) throw new Error("Set USDC_ADDRESS (or add usdc to the network's config).");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Network:", net);
  console.log("VRF coordinator:", coordinator, "| native payment:", nativePayment);
  console.log("USDC:", usdc);

  // 1. PotScore — soulbound reputation registry.
  const PotScore = await hre.ethers.getContractFactory("PotScore");
  const score = await PotScore.deploy();
  await score.waitForDeployment();
  const scoreAddr = await score.getAddress();
  console.log("PotScore deployed:", scoreAddr);

  // 2. PotFactory — pool deployer + index + VRF subscription owner.
  const PotFactory = await hre.ethers.getContractFactory("PotFactory");
  const factory = await PotFactory.deploy(
    scoreAddr,
    treasury,
    usdc,
    coordinator,
    keyHash,
    callbackGasLimit,
    requestConfirmations,
    nativePayment
  );
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("PotFactory deployed:", factoryAddr);

  // 3. Transfer PotScore ownership to the factory so createPool() can authorize pools.
  const tx = await score.transferOwnership(factoryAddr);
  await tx.wait();
  console.log("PotScore ownership transferred to factory.");

  const subId = await factory.vrfSubId();

  console.log("\nDeployment complete:");
  console.log("  PotScore     :", scoreAddr);
  console.log("  PotFactory   :", factoryAddr);
  console.log("  Treasury     :", treasury);
  console.log("  VRF subId    :", subId.toString());

  console.log("\n>>> ACTION REQUIRED: fund the VRF subscription before starting any pool.");
  if (nativePayment) {
    console.log(
      `    Native (ETH): call fundSubscriptionWithNative(${subId}) on the coordinator ${coordinator}`
    );
    console.log("    e.g. coordinator.fundSubscriptionWithNative(subId, { value: <ETH amount> })");
  } else {
    const link = (defaults && defaults.link) || "<LINK token>";
    console.log(
      `    LINK: transferAndCall ${link} -> coordinator ${coordinator} with abi-encoded subId ${subId}`
    );
  }

  console.log("\nVerify with:");
  console.log(`  npx hardhat verify --network ${net} ${scoreAddr}`);
  console.log(
    `  npx hardhat verify --network ${net} ${factoryAddr} ` +
      `${scoreAddr} ${treasury} ${usdc} ${coordinator} ${keyHash} ${callbackGasLimit} ${requestConfirmations} ${nativePayment}`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
