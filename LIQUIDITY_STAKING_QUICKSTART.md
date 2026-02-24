# XDC 流动性质押系统 - 快速开始

## 🚀 快速部署

### 1. 部署合约

```bash
npx hardhat run scripts/liquidityStakingDeploy.js --network xdc
```

部署完成后，您将看到：
- XDCLiquidityStaking 合约地址
- bXDC 代币地址

### 2. 保存合约地址

```bash
export STAKING_POOL_ADDRESS=0x...  # 替换为实际地址
```

## 📱 用户操作

### 质押 XDC 获得 bXDC

```javascript
// Web3.js 示例
const amount = web3.utils.toWei('100', 'ether'); // 质押 100 XDC
await stakingPoolContract.methods.stake().send({
    from: userAddress,
    value: amount
});
```

### 查询 bXDC 余额

```javascript
const balance = await bxdcContract.methods.balanceOf(userAddress).call();
console.log('bXDC 余额:', web3.utils.fromWei(balance, 'ether'));
```

### 查询当前兑换比例

```javascript
const rate = await stakingPoolContract.methods.getExchangeRate().call();
console.log('1 bXDC =', web3.utils.fromWei(rate, 'ether'), 'XDC');
```

### 请求赎回

```javascript
// 1. 授权
const bxdcAmount = web3.utils.toWei('10', 'ether');
await bxdcContract.methods.approve(stakingPoolAddress, bxdcAmount).send({
    from: userAddress
});

// 2. 请求赎回
await stakingPoolContract.methods.requestWithdrawal(bxdcAmount).send({
    from: userAddress
});
```

### 查询赎回请求

```javascript
const requestIds = await stakingPoolContract.methods
    .getUserWithdrawalRequests(userAddress)
    .call();

for (let id of requestIds) {
    const request = await stakingPoolContract.methods
        .withdrawalRequests(id)
        .call();
    console.log('请求', id, request);
}
```

## 🔧 管理员操作

### 使用交互式管理工具

```bash
STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingAdmin.js --network xdc
```

这将打开一个交互式菜单，包含所有管理功能：

1. **查看合约状态** - 总览所有数据
2. **查看待处理赎回** - 列出所有待审核的请求
3. **批准赎回** - 批准单个赎回请求
4. **批量批准** - 一次批准多个请求
5. **拒绝赎回** - 拒绝并返还 bXDC
6. **提取资金** - 提取 XDC 运行 validator
7. **存入奖励** - 存入质押奖励
8. **更新参数** - 调整系统参数
9. **暂停/恢复** - 紧急控制

### 常用管理命令

```bash
# 查看待处理的赎回
npx hardhat console --network xdc
> const pool = await ethers.getContractAt("XDCLiquidityStaking", "0x...")
> await pool.getPendingWithdrawalIds()

# 批准赎回请求 #0
> await pool.approveWithdrawal(0)

# 提取 1000 XDC 运行 validator
> await pool.withdrawForValidator(ethers.utils.parseEther("1000"))

# 归还本金和存入奖励
# 步骤1：直接转账归还本金
> const [owner] = await ethers.getSigners()
> await owner.sendTransaction({ to: "0x...", value: ethers.utils.parseEther("1000") })

# 步骤2：存入奖励（仅奖励部分）
> await pool.depositRewards({ value: ethers.utils.parseEther("50") })
```

## 🔄 典型工作流程

### 日常运营流程

```
1. 用户质押 → 获得 bXDC
2. 管理员定期提取 XDC → 运行 validator 节点
3. Validator 获得奖励
4. 管理员存入奖励 → bXDC 价值自动增长
5. 用户请求赎回
6. 管理员审核并批准 → 用户获得更多 XDC
```

### 示例：完整周期

```bash
# 第 1 天：初始质押
用户A: 质押 100 XDC → 获得 100 bXDC
用户B: 质押 50 XDC  → 获得 50 bXDC
总池化: 150 XDC

# 第 2 天：运行 validator
管理员: 提取 120 XDC 运行节点

# 第 30 天：获得奖励
Validator 奖励: 15 XDC
管理员操作:
  1. 转账 120 XDC 归还本金
  2. 调用 depositRewards 存入 15 XDC 奖励
新比例: 1 bXDC = 1.1 XDC ✨

# 第 31 天：用户赎回
用户A: 赎回 50 bXDC → 获得 55 XDC (赚了 5 XDC!)
```

## 📊 监控与统计

### 关键指标

```javascript
// TVL (总锁仓量)
const tvl = await stakingPoolContract.methods.totalPooledXDC().call();

// APY 计算示例
// APY = (新兑换比例 / 旧兑换比例 - 1) × (365 / 天数) × 100%
const oldRate = 1.0; // 30 天前
const newRate = 1.1; // 现在
const days = 30;
const apy = ((newRate / oldRate - 1) * (365 / days) * 100).toFixed(2);
console.log('APY:', apy, '%');
```

## ⚠️ 重要注意事项

1. **赎回需要审核** - 不是即时的，需要管理员批准
2. **保持流动性** - 合约应保留足够余额处理赎回
3. **定期存入奖励** - 建议每月至少一次
4. **监控待处理请求** - 及时处理用户赎回
5. **测试网先测试** - 主网部署前充分测试

## 🔐 安全建议

1. 使用多签钱包作为管理员
2. 设置合理的最大提取比例（建议不超过 80%）
3. 定期审计合约余额
4. 监控大额赎回请求
5. 在紧急情况下可暂停合约

## 📞 快速命令参考

```bash
# 部署
npx hardhat run scripts/liquidityStakingDeploy.js --network xdc

# 管理工具
STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingAdmin.js --network xdc

# 演示
STAKING_POOL_ADDRESS=0x... npx hardhat run scripts/liquidityStakingDemo.js --network xdc

# 控制台
npx hardhat console --network xdc
```

## 🆘 常见问题

**Q: 用户能立即赎回吗？**
A: 不能，需要管理员审核批准。这是为了确保合约有足够的流动性。

**Q: 兑换比例如何增长？**
A: 当管理员存入质押奖励时，总池化 XDC 增加，但 bXDC 供应量不变，因此比例自动提升。

**Q: 最多能提取多少 XDC？**
A: 默认最多 80%，可由管理员调整。这确保合约始终有足够余额处理赎回。

**Q: 如何计算 APY？**
A: APY = (当前兑换比例 / 初始兑换比例 - 1) × (365 / 持有天数) × 100%

**Q: bXDC 可以交易吗？**
A: 可以，bXDC 是标准的 ERC20 代币，可以自由转账和在 DEX 上交易。

## 📖 详细文档

完整文档请查看：`docs/LIQUIDITY_STAKING_README.md`
