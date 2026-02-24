const hre = require("hardhat");

async function main() {
  // We get the contract to deploy
  const BBBFarmerFactory = await hre.ethers.getContractFactory("USDBStake");

  let BBBFarmer;
  try {
    BBBFarmer = await BBBFarmerFactory.deploy();
  } catch (e) {
    console.error(e, "\n");
    throw Error(
      "deploy to parentnet node failure , pls check the parentnet node status"
    );
  }

  await BBBFarmer.deployed();

  console.log("BBBFarmer deployed to:", BBBFarmer.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
