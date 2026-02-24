const hre = require("hardhat");

async function main() {
    console.log("XDC 流动性质押系统演示\n");

    // 获取账户
    const [owner, user1, user2] = await hre.ethers.getSigners();
    
    // 这里替换为你部署的合约地址
    const STAKING_POOL_ADDRESS = process.env.STAKING_POOL_ADDRESS || "YOUR_STAKING_POOL_ADDRESS";
    
    if (STAKING_POOL_ADDRESS === "YOUR_STAKING_POOL_ADDRESS") {
        console.log("❌ 请先设置环境变量 STAKING_POOL_ADDRESS");
        console.log("例如: STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingDemo.js --network xdc");
        process.exit(1);
    }

    // 连接到已部署的合约
    const stakingPool = await hre.ethers.getContractAt("XDCLiquidityStaking", STAKING_POOL_ADDRESS);
    const bxdcAddress = await stakingPool.bxdcToken();
    const bxdc = await hre.ethers.getContractAt("bXDC", bxdcAddress);

    console.log("合约地址:");
    console.log("- 质押池:", STAKING_POOL_ADDRESS);
    console.log("- bXDC:", bxdcAddress);
    console.log("");

    // ========== 场景 1: 用户质押 XDC ==========
    console.log("========== 场景 1: 用户质押 XDC ==========");
    
    const stakeAmount = hre.ethers.parseEther("100"); // 质押 100 XDC
    console.log(`用户1 质押 ${hre.ethers.formatEther(stakeAmount)} XDC...`);
    
    let tx = await stakingPool.connect(user1).stake({ value: stakeAmount });
    await tx.wait();
    
    let bxdcBalance = await bxdc.balanceOf(user1.address);
    let exchangeRate = await stakingPool.getExchangeRate();
    console.log(`✅ 用户1 获得 ${hre.ethers.formatEther(bxdcBalance)} bXDC`);
    console.log(`当前兑换比例: 1 bXDC = ${hre.ethers.formatEther(exchangeRate)} XDC\n`);

    // ========== 场景 2: 第二个用户质押 ==========
    console.log("========== 场景 2: 第二个用户质押 ==========");
    
    const stakeAmount2 = hre.ethers.parseEther("50");
    console.log(`用户2 质押 ${hre.ethers.formatEther(stakeAmount2)} XDC...`);
    
    tx = await stakingPool.connect(user2).stake({ value: stakeAmount2 });
    await tx.wait();
    
    let bxdcBalance2 = await bxdc.balanceOf(user2.address);
    console.log(`✅ 用户2 获得 ${hre.ethers.formatEther(bxdcBalance2)} bXDC\n`);

    // ========== 场景 3: 管理员提取 XDC 运行 Validator ==========
    console.log("========== 场景 3: 管理员提取 XDC 运行 Validator ==========");
    
    const withdrawAmount = hre.ethers.parseEther("100");
    console.log(`管理员提取 ${hre.ethers.formatEther(withdrawAmount)} XDC 用于运行 validator...`);
    
    tx = await stakingPool.connect(owner).withdrawForValidator(withdrawAmount);
    await tx.wait();
    console.log("✅ 提取成功\n");

    // ========== 场景 4: 管理员归还本金和存入奖励 ==========
    console.log("========== 场景 4: 管理员归还本金和存入奖励 ==========");
    
    // 步骤1：归还本金
    console.log(`管理员归还 ${hre.ethers.formatEther(withdrawAmount)} XDC 本金...`);
    tx = await owner.sendTransaction({
        to: STAKING_POOL_ADDRESS,
        value: withdrawAmount
    });
    await tx.wait();
    console.log("✅ 本金已归还");
    
    // 步骤2：存入奖励
    const rewardAmount = hre.ethers.parseEther("10"); // 获得 10 XDC 奖励
    console.log(`\n管理员存入 ${hre.ethers.formatEther(rewardAmount)} XDC 质押奖励...`);
    
    tx = await stakingPool.connect(owner).depositRewards({ value: rewardAmount });
    await tx.wait();
    
    exchangeRate = await stakingPool.getExchangeRate();
    console.log(`✅ 奖励已存入`);
    console.log(`新的兑换比例: 1 bXDC = ${hre.ethers.formatEther(exchangeRate)} XDC`);
    console.log(`📈 兑换比例提升！用户的 bXDC 现在更值钱了\n`);

    // ========== 场景 5: 用户请求赎回 ==========
    console.log("========== 场景 5: 用户请求赎回 ==========");
    
    const withdrawbXDC = hre.ethers.parseEther("10");
    const expectedXDC = await stakingPool.getXDCBybXDC(withdrawbXDC);
    
    console.log(`用户1 请求赎回 ${hre.ethers.formatEther(withdrawbXDC)} bXDC...`);
    console.log(`预计可获得 ${hre.ethers.formatEther(expectedXDC)} XDC`);
    
    // 先授权
    tx = await bxdc.connect(user1).approve(STAKING_POOL_ADDRESS, withdrawbXDC);
    await tx.wait();
    
    tx = await stakingPool.connect(user1).requestWithdrawal(withdrawbXDC);
    const receipt = await tx.wait();
    
    // 获取请求ID
    const event = receipt.logs.find(log => {
        try {
            return stakingPool.interface.parseLog(log).name === 'WithdrawalRequested';
        } catch {
            return false;
        }
    });
    const requestId = stakingPool.interface.parseLog(event).args.requestId;
    
    console.log(`✅ 赎回请求已提交，请求ID: ${requestId}\n`);

    // ========== 场景 6: 查看待处理的赎回请求 ==========
    console.log("========== 场景 6: 查看待处理的赎回请求 ==========");
    
    const pendingIds = await stakingPool.getPendingWithdrawalIds();
    console.log(`待处理的赎回请求: ${pendingIds.length} 个`);
    
    for (let id of pendingIds) {
        const request = await stakingPool.withdrawalRequests(id);
        console.log(`  请求 #${id}:`);
        console.log(`    用户: ${request.user}`);
        console.log(`    bXDC 数量: ${hre.ethers.formatEther(request.bxdcAmount)}`);
        console.log(`    XDC 数量: ${hre.ethers.formatEther(request.xdcAmount)}`);
    }
    console.log("");

    // ========== 场景 7: 管理员批准赎回 ==========
    console.log("========== 场景 7: 管理员批准赎回 ==========");
    
    console.log(`管理员批准赎回请求 #${requestId}...`);
    
    const user1BalanceBefore = await hre.ethers.provider.getBalance(user1.address);
    
    tx = await stakingPool.connect(owner).approveWithdrawal(requestId);
    await tx.wait();
    
    const user1BalanceAfter = await hre.ethers.provider.getBalance(user1.address);
    const received = user1BalanceAfter - user1BalanceBefore;
    
    console.log(`✅ 赎回已批准`);
    console.log(`用户1 收到 ${hre.ethers.formatEther(received)} XDC\n`);

    // ========== 最终状态 ==========
    console.log("========== 最终状态 ==========");
    
    const totalPooled = await stakingPool.totalPooledXDC();
    const contractBalance = await hre.ethers.provider.getBalance(STAKING_POOL_ADDRESS);
    const totalSupply = await bxdc.totalSupply();
    const finalRate = await stakingPool.getExchangeRate();
    
    console.log(`总池化 XDC: ${hre.ethers.formatEther(totalPooled)}`);
    console.log(`合约 XDC 余额: ${hre.ethers.formatEther(contractBalance)}`);
    console.log(`bXDC 总供应: ${hre.ethers.formatEther(totalSupply)}`);
    console.log(`最终兑换比例: 1 bXDC = ${hre.ethers.formatEther(finalRate)} XDC`);
    
    const user1FinalBalance = await bxdc.balanceOf(user1.address);
    const user2FinalBalance = await bxdc.balanceOf(user2.address);
    console.log(`\n用户1 bXDC 余额: ${hre.ethers.formatEther(user1FinalBalance)}`);
    console.log(`用户2 bXDC 余额: ${hre.ethers.formatEther(user2FinalBalance)}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
