const hre = require("hardhat");

async function main() {
  // We get the contract to deploy
  const referralProgramFactory = await hre.ethers.getContractFactory(
    "sUSDB"
  );

  let referralProgram;
  try {
    referralProgram = await referralProgramFactory.deploy();
  } catch (e) {
    console.error(e, "\n");
    throw Error(
      "deploy to parentnet node failure , pls check the parentnet node status"
    );
  }

  await referralProgram.deployed();

  console.log("ReferralProgram deployed to:", referralProgram.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
