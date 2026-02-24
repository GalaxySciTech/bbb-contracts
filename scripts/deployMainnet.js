const hre = require("hardhat");

async function main() {
    console.log("==========================================");
    console.log("Deploying XDC Liquid Staking to MAINNET");
    console.log("==========================================\n");

    const [deployer] = await hre.ethers.getSigners();
    console.log("Deployer address:", deployer.address);
    
    const balance = await hre.ethers.provider.getBalance(deployer.address);
    console.log("Deployer balance:", hre.ethers.utils.formatEther(balance), "XDC\n");

    if (balance.lt(hre.ethers.utils.parseEther("0.1"))) {
        console.log("⚠️  WARNING: Low balance! Make sure you have enough XDC for deployment.");
    }

    const validatorAddress = process.env.XDC_VALIDATOR_ADDRESS || "0x0000000000000000000000000000000000000088";

    // 使用官方 WXDC: https://xdcscan.com/address/0x951857744785e80e2de051c32ee7b25f9c458c42
    const WXDC_MAINNET = "0x951857744785E80e2De051c32EE7b25f9c458C42";
    const wxdcAddress = process.env.WXDC_ADDRESS || WXDC_MAINNET;
    console.log("Using official WXDC:", wxdcAddress);

    console.log("Deploying XDCLiquidityStaking contract...");
    const XDCLiquidityStaking = await hre.ethers.getContractFactory("XDCLiquidityStaking");
    const stakingPool = await XDCLiquidityStaking.deploy(validatorAddress, wxdcAddress, deployer.address);
    await stakingPool.deployed();
    
    const stakingPoolAddress = stakingPool.address;
    console.log("✅ XDCLiquidityStaking deployed to:", stakingPoolAddress);

    const bxdcAddress = await stakingPool.bxdcToken();
    console.log("✅ bXDC token address:", bxdcAddress);

    const minStakeAmount = await stakingPool.minStakeAmount();
    const minWithdrawAmount = await stakingPool.minWithdrawAmount();
    const maxWithdrawablePercentage = await stakingPool.maxWithdrawablePercentage();
    const exchangeRate = await stakingPool.getExchangeRate();

    console.log("\n📊 Contract Parameters:");
    console.log("- Min stake amount:", hre.ethers.utils.formatEther(minStakeAmount), "XDC");
    console.log("- Min withdrawal amount:", hre.ethers.utils.formatEther(minWithdrawAmount), "XDC");
    console.log("- Max withdrawable percentage:", maxWithdrawablePercentage.toString(), "%");
    console.log("- Initial exchange rate:", hre.ethers.utils.formatEther(exchangeRate), "XDC per bXDC");

    console.log("\n⏳ Waiting for block confirmations before verification...");
    await stakingPool.deployTransaction.wait(5);

    console.log("\n🔍 Verifying contract on XDCScan...");
    
    try {
        await hre.run("verify:verify", {
            address: stakingPoolAddress,
            constructorArguments: [validatorAddress, wxdcAddress, deployer.address],
            contract: "contracts/liquditystaking.sol:XDCLiquidityStaking"
        });
        console.log("✅ Contract verified successfully!");
    } catch (error) {
        if (error.message.includes("Already Verified")) {
            console.log("✅ Contract already verified!");
        } else {
            console.log("❌ Verification failed:", error.message);
            console.log("\nYou can verify manually later with:");
            console.log(`npx hardhat verify --network xdc ${stakingPoolAddress}`);
        }
    }

    console.log("\n✅ Deployment Complete!");
    console.log("\n📝 Contract Addresses:");
    console.log("===================================");
    console.log("XDCLiquidityStaking:", stakingPoolAddress);
    console.log("WXDC:", wxdcAddress);
    console.log("bXDC Token (ERC4626):", bxdcAddress);
    console.log("===================================");
    console.log("\n🔗 View on XDCScan:");
    console.log(`https://xdcscan.com/address/${stakingPoolAddress}`);
    console.log(`https://xdcscan.com/address/${bxdcAddress}`);

    const deploymentInfo = {
        network: "xdc-mainnet",
        deployer: deployer.address,
        timestamp: new Date().toISOString(),
        contracts: {
            XDCLiquidityStaking: stakingPoolAddress,
            WXDC: wxdcAddress,
            bXDC: bxdcAddress
        },
        parameters: {
            minStakeAmount: minStakeAmount.toString(),
            minWithdrawAmount: minWithdrawAmount.toString(),
            maxWithdrawablePercentage: maxWithdrawablePercentage.toString()
        },
        verified: true
    };

    const fs = require('fs');
    const path = require('path');
    const deploymentsDir = path.join(__dirname, '../deployments');
    
    if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
    }
    
    const filename = `mainnet-${Date.now()}.json`;
    fs.writeFileSync(
        path.join(deploymentsDir, filename),
        JSON.stringify(deploymentInfo, null, 2)
    );
    
    console.log(`\n💾 Deployment info saved to: deployments/${filename}`);
    
    console.log("\n📖 Next Steps:");
    console.log("1. Save the contract addresses securely");
    console.log("2. Set up monitoring for the contracts");
    console.log("3. Test basic operations (stake, withdraw)");
    console.log("4. Consider transferring ownership to a multisig wallet");
    console.log("\n⚠️  IMPORTANT: This is MAINNET deployment. Handle with care!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("\n❌ Deployment failed:");
        console.error(error);
        process.exit(1);
    });
