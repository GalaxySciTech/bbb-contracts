const hre = require("hardhat");
const readline = require('readline');

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

function question(query) {
    return new Promise(resolve => rl.question(query, resolve));
}

async function displayMenu() {
    console.log("\n╔═══════════════════════════════════════════════╗");
    console.log("║   XDC 流动性质押系统 - 管理员工具           ║");
    console.log("╚═══════════════════════════════════════════════╝");
    console.log("\n请选择操作：");
    console.log("1. 查看合约状态");
    console.log("2. 查看待处理的赎回请求");
    console.log("3. 批准赎回请求");
    console.log("4. 批量批准赎回请求");
    console.log("5. 拒绝赎回请求");
    console.log("6. 提取 XDC 运行 validator");
    console.log("7. 归还 validator 本金");
    console.log("8. 存入质押奖励");
    console.log("9. 更新参数");
    console.log("10. 暂停/恢复合约");
    console.log("0. 退出");
    console.log("");
}

async function displayContractStatus(stakingPool, bxdc) {
    console.log("\n========== 合约状态 ==========");
    
    const totalPooled = await stakingPool.totalPooledXDC();
    const contractBalance = await hre.ethers.provider.getBalance(await stakingPool.getAddress());
    const totalSupply = await bxdc.totalSupply();
    const exchangeRate = await stakingPool.getExchangeRate();
    const minStake = await stakingPool.minStakeAmount();
    const minWithdraw = await stakingPool.minWithdrawAmount();
    const maxWithdrawPercentage = await stakingPool.maxWithdrawablePercentage();
    const isPaused = await stakingPool.paused();
    
    console.log(`状态: ${isPaused ? '❌ 已暂停' : '✅ 运行中'}`);
    console.log(`总池化 XDC: ${hre.ethers.formatEther(totalPooled)} XDC`);
    console.log(`合约余额: ${hre.ethers.formatEther(contractBalance)} XDC`);
    console.log(`运行中的资金: ${hre.ethers.formatEther(totalPooled - contractBalance)} XDC`);
    console.log(`bXDC 总供应: ${hre.ethers.formatEther(totalSupply)} bXDC`);
    console.log(`兑换比例: 1 bXDC = ${hre.ethers.formatEther(exchangeRate)} XDC`);
    console.log(`最小质押: ${hre.ethers.formatEther(minStake)} XDC`);
    console.log(`最小赎回: ${hre.ethers.formatEther(minWithdraw)} XDC`);
    console.log(`最大可提取比例: ${maxWithdrawPercentage}%`);
    
    const pendingCount = await stakingPool.getPendingWithdrawalCount();
    console.log(`待处理赎回请求: ${pendingCount} 个`);
}

async function displayPendingWithdrawals(stakingPool) {
    console.log("\n========== 待处理的赎回请求 ==========");
    
    const pendingIds = await stakingPool.getPendingWithdrawalIds();
    
    if (pendingIds.length === 0) {
        console.log("没有待处理的赎回请求");
        return;
    }
    
    for (let id of pendingIds) {
        const request = await stakingPool.withdrawalRequests(id);
        const date = new Date(Number(request.requestTime) * 1000);
        
        console.log(`\n请求 #${id}:`);
        console.log(`  用户: ${request.user}`);
        console.log(`  bXDC 数量: ${hre.ethers.formatEther(request.bxdcAmount)}`);
        console.log(`  XDC 数量: ${hre.ethers.formatEther(request.xdcAmount)}`);
        console.log(`  请求时间: ${date.toLocaleString()}`);
    }
}

async function approveWithdrawal(stakingPool) {
    const requestId = await question("\n请输入要批准的赎回请求 ID: ");
    
    try {
        const id = parseInt(requestId);
        const request = await stakingPool.withdrawalRequests(id);
        
        console.log(`\n准备批准请求 #${id}:`);
        console.log(`  用户: ${request.user}`);
        console.log(`  将支付: ${hre.ethers.formatEther(request.xdcAmount)} XDC`);
        
        const confirm = await question("\n确认批准？(y/n): ");
        
        if (confirm.toLowerCase() === 'y') {
            console.log("正在处理...");
            const tx = await stakingPool.approveWithdrawal(id);
            await tx.wait();
            console.log("✅ 赎回请求已批准");
        } else {
            console.log("已取消");
        }
    } catch (error) {
        console.error("❌ 操作失败:", error.message);
    }
}

async function batchApproveWithdrawals(stakingPool) {
    const input = await question("\n请输入要批准的请求 ID（用逗号分隔，例如: 0,1,2）: ");
    
    try {
        const ids = input.split(',').map(s => parseInt(s.trim()));
        
        console.log(`\n准备批准 ${ids.length} 个赎回请求: ${ids.join(', ')}`);
        
        let totalXDC = 0n;
        for (let id of ids) {
            const request = await stakingPool.withdrawalRequests(id);
            if (!request.processed) {
                totalXDC += request.xdcAmount;
            }
        }
        
        console.log(`总计将支付: ${hre.ethers.formatEther(totalXDC)} XDC`);
        
        const confirm = await question("\n确认批量批准？(y/n): ");
        
        if (confirm.toLowerCase() === 'y') {
            console.log("正在处理...");
            const tx = await stakingPool.batchApproveWithdrawals(ids);
            await tx.wait();
            console.log("✅ 批量批准完成");
        } else {
            console.log("已取消");
        }
    } catch (error) {
        console.error("❌ 操作失败:", error.message);
    }
}

async function rejectWithdrawal(stakingPool) {
    const requestId = await question("\n请输入要拒绝的赎回请求 ID: ");
    
    try {
        const id = parseInt(requestId);
        const request = await stakingPool.withdrawalRequests(id);
        
        console.log(`\n准备拒绝请求 #${id}:`);
        console.log(`  用户: ${request.user}`);
        console.log(`  将返还: ${hre.ethers.formatEther(request.bxdcAmount)} bXDC`);
        
        const confirm = await question("\n确认拒绝？(y/n): ");
        
        if (confirm.toLowerCase() === 'y') {
            console.log("正在处理...");
            const tx = await stakingPool.rejectWithdrawal(id);
            await tx.wait();
            console.log("✅ 赎回请求已拒绝，bXDC 已返还");
        } else {
            console.log("已取消");
        }
    } catch (error) {
        console.error("❌ 操作失败:", error.message);
    }
}

async function withdrawForValidator(stakingPool) {
    const totalPooled = await stakingPool.totalPooledXDC();
    const contractBalance = await hre.ethers.provider.getBalance(await stakingPool.getAddress());
    const maxPercentage = await stakingPool.maxWithdrawablePercentage();
    
    console.log(`\n当前合约余额: ${hre.ethers.formatEther(contractBalance)} XDC`);
    console.log(`总池化 XDC: ${hre.ethers.formatEther(totalPooled)} XDC`);
    console.log(`最大可提取比例: ${maxPercentage}%`);
    
    const amount = await question("\n请输入要提取的 XDC 数量: ");
    
    try {
        const withdrawAmount = hre.ethers.parseEther(amount);
        
        console.log(`\n准备提取 ${amount} XDC 用于运行 validator`);
        
        const confirm = await question("\n确认提取？(y/n): ");
        
        if (confirm.toLowerCase() === 'y') {
            console.log("正在处理...");
            const tx = await stakingPool.withdrawForValidator(withdrawAmount);
            await tx.wait();
            console.log("✅ 提取成功");
        } else {
            console.log("已取消");
        }
    } catch (error) {
        console.error("❌ 操作失败:", error.message);
    }
}

async function returnPrincipal(owner, stakingPool) {
    const contractBalance = await hre.ethers.provider.getBalance(await stakingPool.getAddress());
    const totalPooled = await stakingPool.totalPooledXDC();
    
    console.log(`\n合约当前余额: ${hre.ethers.formatEther(contractBalance)} XDC`);
    console.log(`总池化 XDC: ${hre.ethers.formatEther(totalPooled)} XDC`);
    console.log(`在外运行的资金: ${hre.ethers.formatEther(totalPooled - contractBalance)} XDC`);
    
    const amount = await question("\n请输入要归还的本金数量: ");
    
    try {
        const returnAmount = hre.ethers.parseEther(amount);
        
        console.log(`\n准备归还 ${amount} XDC 本金（直接转账，不改变 totalPooledXDC）`);
        
        const confirm = await question("\n确认归还？(y/n): ");
        
        if (confirm.toLowerCase() === 'y') {
            console.log("正在处理...");
            const tx = await owner.sendTransaction({
                to: await stakingPool.getAddress(),
                value: returnAmount
            });
            await tx.wait();
            console.log("✅ 本金已归还");
            
            const newBalance = await hre.ethers.provider.getBalance(await stakingPool.getAddress());
            console.log(`合约新余额: ${hre.ethers.formatEther(newBalance)} XDC`);
        } else {
            console.log("已取消");
        }
    } catch (error) {
        console.error("❌ 操作失败:", error.message);
    }
}

async function depositRewards(stakingPool) {
    const currentRate = await stakingPool.getExchangeRate();
    console.log(`\n当前兑换比例: 1 bXDC = ${hre.ethers.formatEther(currentRate)} XDC`);
    console.log("\n⚠️  注意: 此功能仅用于存入奖励部分，不包括本金");
    console.log("如需归还本金，请先使用选项7");
    
    const amount = await question("\n请输入要存入的奖励 XDC 数量（仅奖励）: ");
    
    try {
        const rewardAmount = hre.ethers.parseEther(amount);
        
        const totalPooled = await stakingPool.totalPooledXDC();
        const totalSupply = await stakingPool.bxdcToken().then(addr => 
            hre.ethers.getContractAt("bXDC", addr).then(c => c.totalSupply())
        );
        
        const newTotalPooled = totalPooled + rewardAmount;
        const newRate = (newTotalPooled * 1000000n) / totalSupply / 1000000n;
        
        console.log(`\n准备存入 ${amount} XDC 奖励`);
        console.log(`新的兑换比例将约为: 1 bXDC ≈ ${hre.ethers.formatEther(newRate)} XDC`);
        
        const confirm = await question("\n确认存入？(y/n): ");
        
        if (confirm.toLowerCase() === 'y') {
            console.log("正在处理...");
            const tx = await stakingPool.depositRewards({ value: rewardAmount });
            await tx.wait();
            console.log("✅ 奖励已存入");
            
            const actualNewRate = await stakingPool.getExchangeRate();
            console.log(`实际新兑换比例: 1 bXDC = ${hre.ethers.formatEther(actualNewRate)} XDC`);
        } else {
            console.log("已取消");
        }
    } catch (error) {
        console.error("❌ 操作失败:", error.message);
    }
}

async function updateParameters(stakingPool) {
    console.log("\n========== 更新参数 ==========");
    console.log("1. 最小质押数量");
    console.log("2. 最小赎回数量");
    console.log("3. 最大可提取比例");
    console.log("0. 返回");
    
    const choice = await question("\n请选择: ");
    
    try {
        switch (choice) {
            case '1': {
                const amount = await question("请输入新的最小质押数量（XDC）: ");
                const tx = await stakingPool.setMinStakeAmount(hre.ethers.parseEther(amount));
                await tx.wait();
                console.log("✅ 最小质押数量已更新");
                break;
            }
            case '2': {
                const amount = await question("请输入新的最小赎回数量（XDC）: ");
                const tx = await stakingPool.setMinWithdrawAmount(hre.ethers.parseEther(amount));
                await tx.wait();
                console.log("✅ 最小赎回数量已更新");
                break;
            }
            case '3': {
                const percentage = await question("请输入新的最大可提取比例（%）: ");
                const tx = await stakingPool.setMaxWithdrawablePercentage(parseInt(percentage));
                await tx.wait();
                console.log("✅ 最大可提取比例已更新");
                break;
            }
        }
    } catch (error) {
        console.error("❌ 操作失败:", error.message);
    }
}

async function togglePause(stakingPool) {
    const isPaused = await stakingPool.paused();
    
    console.log(`\n当前状态: ${isPaused ? '已暂停' : '运行中'}`);
    console.log(`准备${isPaused ? '恢复' : '暂停'}合约`);
    
    const confirm = await question(`\n确认${isPaused ? '恢复' : '暂停'}？(y/n): `);
    
    if (confirm.toLowerCase() === 'y') {
        try {
            console.log("正在处理...");
            const tx = isPaused ? await stakingPool.unpause() : await stakingPool.pause();
            await tx.wait();
            console.log(`✅ 合约已${isPaused ? '恢复' : '暂停'}`);
        } catch (error) {
            console.error("❌ 操作失败:", error.message);
        }
    } else {
        console.log("已取消");
    }
}

async function main() {
    const STAKING_POOL_ADDRESS = process.env.STAKING_POOL_ADDRESS;
    
    if (!STAKING_POOL_ADDRESS) {
        console.log("❌ 请设置环境变量 STAKING_POOL_ADDRESS");
        console.log("例如: STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingAdmin.js --network xdc");
        process.exit(1);
    }
    
    const [owner] = await hre.ethers.getSigners();
    console.log(`\n管理员账户: ${owner.address}`);
    
    const stakingPool = await hre.ethers.getContractAt("XDCLiquidityStaking", STAKING_POOL_ADDRESS);
    const bxdcAddress = await stakingPool.bxdcToken();
    const bxdc = await hre.ethers.getContractAt("bXDC", bxdcAddress);
    
    console.log(`质押池地址: ${STAKING_POOL_ADDRESS}`);
    console.log(`bXDC 地址: ${bxdcAddress}`);
    
    let running = true;
    
    while (running) {
        await displayMenu();
        const choice = await question("请选择操作: ");
        
        switch (choice) {
            case '1':
                await displayContractStatus(stakingPool, bxdc);
                break;
            case '2':
                await displayPendingWithdrawals(stakingPool);
                break;
            case '3':
                await approveWithdrawal(stakingPool);
                break;
            case '4':
                await batchApproveWithdrawals(stakingPool);
                break;
            case '5':
                await rejectWithdrawal(stakingPool);
                break;
            case '6':
                await withdrawForValidator(stakingPool);
                break;
            case '7':
                await returnPrincipal(owner, stakingPool);
                break;
            case '8':
                await depositRewards(stakingPool);
                break;
            case '9':
                await updateParameters(stakingPool);
                break;
            case '10':
                await togglePause(stakingPool);
                break;
            case '0':
                console.log("\n再见！");
                running = false;
                break;
            default:
                console.log("无效的选择");
        }
    }
    
    rl.close();
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
