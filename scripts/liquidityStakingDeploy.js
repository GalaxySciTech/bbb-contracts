const hre = require("hardhat");

async function main() {
    console.log("开始部署 XDC 流动性质押系统...");

    // 获取部署账户
    const [deployer] = await hre.ethers.getSigners();
    console.log("部署账户:", deployer.address);
    console.log("账户余额:", hre.ethers.utils.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "XDC");

    // XDC validator 预编译合约地址 (mainnet: 0x0000000000000000000000000000000000000088)
    const validatorAddress = process.env.XDC_VALIDATOR_ADDRESS || "0x0000000000000000000000000000000000000088";

    // WXDC: 主网使用官方合约 https://xdcscan.com/address/0x951857744785e80e2de051c32ee7b25f9c458c42
    const WXDC_MAINNET = "0x951857744785E80e2De051c32EE7b25f9c458C42";
    let wxdcAddress;
    if (hre.network.name === "xdc" || hre.network.name === "xdc-mainnet") {
        wxdcAddress = process.env.WXDC_ADDRESS || WXDC_MAINNET;
        console.log("\n使用官方 WXDC 合约:", wxdcAddress);
    } else {
        console.log("\n部署 WXDC 合约 (测试网)...");
        const WXDC = await hre.ethers.getContractFactory("WXDC");
        const wxdc = await WXDC.deploy();
        await wxdc.deployed();
        wxdcAddress = wxdc.address;
        console.log("✅ WXDC 合约已部署:", wxdcAddress);
    }

    // 部署 XDCLiquidityStaking 合约（会自动创建 bXDC ERC4626 代币和 WithdrawalRequestNFT）
    console.log("\n部署 XDCLiquidityStaking 合约...");
    const XDCLiquidityStaking = await hre.ethers.getContractFactory("XDCLiquidityStaking");
    const stakingPool = await XDCLiquidityStaking.deploy(validatorAddress, wxdcAddress);
    await stakingPool.deployed();
    const stakingPoolAddress = stakingPool.address;
    console.log("✅ XDCLiquidityStaking 合约已部署:", stakingPoolAddress);

    // 获取 bXDC 代币和 WithdrawalRequestNFT 地址
    const bxdcAddress = await stakingPool.bxdcToken();
    const withdrawalNFTAddress = await stakingPool.withdrawalNFT();
    console.log("✅ bXDC 代币地址:", bxdcAddress);
    console.log("✅ WithdrawalRequestNFT 地址:", withdrawalNFTAddress);

    // 获取初始参数
    const minStakeAmount = await stakingPool.minStakeAmount();
    const minWithdrawAmount = await stakingPool.minWithdrawAmount();
    const maxWithdrawablePercentage = await stakingPool.maxWithdrawablePercentage();
    const exchangeRate = await stakingPool.getExchangeRate();

    console.log("\n📊 合约初始参数:");
    console.log("- 最小质押数量:", hre.ethers.utils.formatEther(minStakeAmount), "XDC");
    console.log("- 最小赎回数量:", hre.ethers.utils.formatEther(minWithdrawAmount), "XDC");
    console.log("- 最大可提取比例:", maxWithdrawablePercentage.toString(), "%");
    console.log("- 当前兑换比例:", hre.ethers.utils.formatEther(exchangeRate), "XDC per bXDC");

    console.log("\n✅ 部署完成!");
    console.log("\n📝 合约地址汇总:");
    console.log("===================================");
    console.log("质押池合约:", stakingPoolAddress);
    console.log("WXDC:", wxdcAddress);
    console.log("bXDC 代币 (ERC4626):", bxdcAddress);
    console.log("===================================");

    console.log("\n📖 使用说明:");
    console.log("1. 管理员调用 submitKYC(kycHash) 提交 LSP KYC");
    console.log("2. 管理员调用 addOperator(addr) 添加 KYC 验证的 operator");
    console.log("3. 用户调用 stake() 并发送 XDC 来质押，获得 bXDC");
    console.log("4. 用户调用 withdraw(bxdcAmount) 赎回 - 有即时缓冲则立即到账，否则获得 NFT");
    console.log("5. NFT 持有者等待解锁后调用 redeemWithdrawal(batchId) 赎回 XDC");
    console.log("6. 管理员调用 addToInstantExitBuffer() 增加即时退出缓冲");
    console.log("7. 管理员调用 depositRewards() 存入奖励更新兑换比例");

    // 保存部署信息
    const deploymentInfo = {
        network: hre.network.name,
        deployer: deployer.address,
        contracts: {
            XDCLiquidityStaking: stakingPoolAddress,
            WXDC: wxdcAddress,
            bXDC: bxdcAddress,
            WithdrawalRequestNFT: withdrawalNFTAddress
        },
        validatorAddress: validatorAddress,
        timestamp: new Date().toISOString(),
        parameters: {
            minStakeAmount: minStakeAmount.toString(),
            minWithdrawAmount: minWithdrawAmount.toString(),
            maxWithdrawablePercentage: maxWithdrawablePercentage.toString()
        }
    };

    const fs = require('fs');
    const path = require('path');
    const deploymentsDir = path.join(__dirname, '../deployments');
    
    if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
    }
    
    const filename = `liquidity-staking-${hre.network.name}-${Date.now()}.json`;
    fs.writeFileSync(
        path.join(deploymentsDir, filename),
        JSON.stringify(deploymentInfo, null, 2)
    );
    
    console.log(`\n💾 部署信息已保存到: deployments/${filename}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
