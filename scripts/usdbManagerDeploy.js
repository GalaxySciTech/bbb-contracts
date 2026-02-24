const { ethers } = require("hardhat");

async function main() {
    console.log("开始部署 USDBManager 合约...");

    // 获取部署者账户
    const [deployer] = await ethers.getSigners();
    console.log("部署者地址:", deployer.address);

    // 检查部署者余额
    const balance = await deployer.provider.getBalance(deployer.address);
    console.log("部署者余额:", ethers.formatEther(balance), "ETH");

    // USDB合约地址 (需要根据实际部署的地址修改)
    const USDB_CONTRACT_ADDRESS = "0xA23885c8E0743C734Bd6Da0df66e2631Ee9Bc6D8";
    
    // 利润目标合约地址 (可以是任何接收利润的合约地址)
    const PROFIT_DESTINATION_ADDRESS = "0x0000000000000000000000000000000000000000"; // 需要设置实际地址

    // 如果没有设置利润目标地址，使用部署者地址作为临时地址
    const profitDestination = PROFIT_DESTINATION_ADDRESS === "0x0000000000000000000000000000000000000000" 
        ? deployer.address 
        : PROFIT_DESTINATION_ADDRESS;

    console.log("USDB合约地址:", USDB_CONTRACT_ADDRESS);
    console.log("利润目标地址:", profitDestination);

    // 获取合约工厂
    const USDBManager = await ethers.getContractFactory("USDBManager");

    // 部署合约
    console.log("正在部署 USDBManager...");
    const usdbManager = await USDBManager.deploy(
        USDB_CONTRACT_ADDRESS,
        profitDestination
    );

    await usdbManager.waitForDeployment();
    const usdbManagerAddress = await usdbManager.getAddress();

    console.log("✅ USDBManager 部署成功!");
    console.log("合约地址:", usdbManagerAddress);

    // 验证部署
    console.log("\n正在验证部署...");
    const deployedUSDBContract = await usdbManager.usdbContract();
    const deployedProfitDestination = await usdbManager.profitDestination();
    
    console.log("验证 - USDB合约地址:", deployedUSDBContract);
    console.log("验证 - 利润目标地址:", deployedProfitDestination);

    // 显示关键信息
    console.log("\n=== 部署完成信息 ===");
    console.log("USDBManager 地址:", usdbManagerAddress);
    console.log("管理费率:", "2%");
    console.log("业绩费率:", "20%");
    console.log("紧急模式:", "false");

    // 提示后续操作
    console.log("\n=== 后续操作建议 ===");
    console.log("1. 将 USDB 合约的 ownership 转移给 USDBManager:");
    console.log(`   usdbContract.transferOwnership("${usdbManagerAddress}")`);
    
    console.log("\n2. 添加投资策略示例:");
    console.log(`   usdbManager.addStrategy("usdb_staking", "${USDB_STAKE_ADDRESS}", 5000, "staking")`);
    console.log(`   usdbManager.addStrategy("lending_protocol", "${LENDING_ADDRESS}", 3000, "lending")`);
    
    console.log("\n3. 从 USDB 合约提取资金:");
    console.log(`   usdbManager.withdrawFromUSDB(tokenAddress, amount)`);
    
    console.log("\n4. 执行投资:");
    console.log(`   usdbManager.executeInvestment("usdb_staking", tokenAddress, amount)`);

    // 保存部署信息
    const deploymentInfo = {
        network: await deployer.provider.getNetwork(),
        deployer: deployer.address,
        usdbManager: usdbManagerAddress,
        usdbContract: USDB_CONTRACT_ADDRESS,
        profitDestination: profitDestination,
        timestamp: new Date().toISOString(),
        blockNumber: await deployer.provider.getBlockNumber()
    };

    console.log("\n部署信息已保存:", JSON.stringify(deploymentInfo, null, 2));

    return usdbManagerAddress;
}

// 相关合约地址常量 (需要根据实际情况修改)
const USDB_STAKE_ADDRESS = "0x0000000000000000000000000000000000000000"; // USDBStake合约地址
const LENDING_ADDRESS = "0x0000000000000000000000000000000000000000";    // 借贷协议地址

main()
    .then((address) => {
        console.log(`\n🎉 USDBManager 成功部署到: ${address}`);
        process.exit(0);
    })
    .catch((error) => {
        console.error("❌ 部署失败:", error);
        process.exit(1);
    }); 