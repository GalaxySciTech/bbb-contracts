# XDC 流动性质押系统

## 概述

这是一个类似于 Lido 的流动性质押系统，允许用户质押 XDC 并获得流动性凭证代币 bXDC。bXDC 与 XDC 的兑换比例会随着质押奖励的增加而动态变化，使持有者能够享受质押收益。

## 核心功能

### 1. 用户功能

#### 质押 XDC
- 用户发送 XDC 到合约，按当前兑换比例获得 bXDC
- 最小质押数量：1 XDC（可调整）
- bXDC 可自由转账和交易

#### 请求赎回
- 用户可以用 bXDC 兑换回 XDC
- 需要管理员审核批准
- 最小赎回数量：0.1 XDC（可调整）

### 2. 管理员功能

#### 审核赎回请求
- 批准或拒绝用户的赎回请求
- 支持批量批准操作
- 拒绝的请求会返还 bXDC 给用户

#### 提取 XDC 运行 Validator
- 提取合约中的 XDC 用于运行验证节点
- 最多可提取总池化 XDC 的 80%（可调整）
- 确保合约流动性

#### 存入质押奖励
- 将 validator 获得的质押奖励存回合约
- 自动更新 bXDC/XDC 兑换比例
- 所有 bXDC 持有者自动享受收益

## 兑换比例机制

### 初始状态
- 1 bXDC = 1 XDC (1:1)

### 收益增长
当管理员存入质押奖励后，兑换比例会提升。例如：
- 初始：100 XDC 质押，铸造 100 bXDC
- 获得奖励：10 XDC
- 新比例：1 bXDC = 1.1 XDC
- 持有者价值增长 10%

### 计算公式
```
兑换比例 = 总池化 XDC / bXDC 总供应量

bXDC 数量 = XDC 数量 × bXDC 总供应量 / 总池化 XDC

XDC 数量 = bXDC 数量 × 总池化 XDC / bXDC 总供应量
```

## 合约架构

### bXDC 合约
- ERC20 代币
- 名称：Staked XDC
- 符号：bXDC
- 只能由质押池合约铸造和销毁

### XDCLiquidityStaking 合约
- 主要质押逻辑
- 管理质押和赎回
- 控制兑换比例
- 处理 validator 资金

## 部署步骤

1. 部署合约：
```bash
npx hardhat run scripts/liquidityStakingDeploy.js --network xdc
```

2. 保存合约地址（会自动保存到 deployments 目录）

3. 验证合约（可选）：
```bash
npx hardhat verify --network xdc <STAKING_POOL_ADDRESS>
```

## 使用示例

### 用户质押

```javascript
// 1. 质押 100 XDC
const stakeAmount = ethers.parseEther("100");
await stakingPool.stake({ value: stakeAmount });

// 2. 查询 bXDC 余额
const balance = await bxdc.balanceOf(userAddress);
console.log(`bXDC 余额: ${ethers.formatEther(balance)}`);
```

### 用户赎回

```javascript
// 1. 授权
const bxdcAmount = ethers.parseEther("10");
await bxdc.approve(stakingPoolAddress, bxdcAmount);

// 2. 请求赎回
await stakingPool.requestWithdrawal(bxdcAmount);

// 3. 查询赎回请求
const requestIds = await stakingPool.getUserWithdrawalRequests(userAddress);
```

### 管理员操作

```javascript
// 1. 批准赎回请求
await stakingPool.approveWithdrawal(requestId);

// 2. 批量批准
await stakingPool.batchApproveWithdrawals([id1, id2, id3]);

// 3. 提取 XDC 运行 validator
const amount = ethers.parseEther("1000");
await stakingPool.withdrawForValidator(amount);

// 4. 归还本金和存入奖励
// 步骤1：直接转账归还本金（不调用任何函数）
await signer.sendTransaction({
    to: stakingPoolAddress,
    value: ethers.parseEther("1000") // 归还本金
});

// 步骤2：调用 depositRewards 存入奖励（仅奖励部分）
const rewards = ethers.parseEther("50");
await stakingPool.depositRewards({ value: rewards });
```

### 查询信息

```javascript
// 1. 查询当前兑换比例
const rate = await stakingPool.getExchangeRate();
console.log(`1 bXDC = ${ethers.formatEther(rate)} XDC`);

// 2. 计算可获得的 bXDC
const bxdcAmount = await stakingPool.getbXDCByXDC(xdcAmount);

// 3. 计算可赎回的 XDC
const xdcAmount = await stakingPool.getXDCBybXDC(bxdcAmount);

// 4. 查询待处理的赎回请求
const pendingIds = await stakingPool.getPendingWithdrawalIds();

// 5. 查询总池化 XDC
const totalPooled = await stakingPool.totalPooledXDC();
```

## 完整工作流程

### 1. 初始阶段
```
用户A 质押 100 XDC → 获得 100 bXDC
用户B 质押 50 XDC  → 获得 50 bXDC
----------------------------------------
总池化: 150 XDC
bXDC 供应: 150
兑换比例: 1:1
```

### 2. 运行 Validator
```
管理员提取 120 XDC 运行 validator 节点
合约余额: 30 XDC（保持流动性）
总池化: 150 XDC（不变）
```

### 3. 获得奖励
```
Validator 获得 15 XDC 奖励
管理员操作：
  1. 直接向合约转账 120 XDC（归还本金，不改变totalPooledXDC）
  2. 调用 depositRewards 存入 15 XDC（仅奖励部分）
----------------------------------------
总池化: 165 XDC (150 + 15)
bXDC 供应: 150（不变）
新兑换比例: 1 bXDC = 1.1 XDC
📈 所有持有者收益 +10%
```

### 4. 用户赎回
```
用户A 赎回 50 bXDC
- 按 1.1 比例可获得 55 XDC
- 提交赎回请求
- 管理员审核批准
- 用户A 收到 55 XDC
----------------------------------------
总池化: 110 XDC
bXDC 供应: 100
兑换比例: 仍为 1:1.1（比例保持）
```

## 安全特性

1. **ReentrancyGuard**: 防止重入攻击
2. **Pausable**: 紧急情况可暂停合约
3. **Ownable**: 关键操作仅管理员可执行
4. **审核机制**: 赎回需要管理员批准
5. **流动性保护**: 限制最大可提取比例

## 参数配置

管理员可调整的参数：

| 参数 | 默认值 | 说明 |
|-----|-------|------|
| minStakeAmount | 1 XDC | 最小质押数量 |
| minWithdrawAmount | 0.1 XDC | 最小赎回数量 |
| maxWithdrawablePercentage | 80% | 最大可提取比例 |

调整方法：
```javascript
await stakingPool.setMinStakeAmount(ethers.parseEther("5"));
await stakingPool.setMinWithdrawAmount(ethers.parseEther("1"));
await stakingPool.setMaxWithdrawablePercentage(70);
```

## 事件日志

合约会发出以下事件用于监控：

- `Staked`: 用户质押
- `WithdrawalRequested`: 赎回请求
- `WithdrawalApproved`: 赎回批准
- `WithdrawalRejected`: 赎回拒绝
- `ValidatorFundsWithdrawn`: 提取资金
- `RewardsDeposited`: 存入奖励

## 运行演示脚本

```bash
# 设置合约地址
export STAKING_POOL_ADDRESS=0x...

# 运行演示
npx hardhat run scripts/liquidityStakingDemo.js --network xdc
```

## 注意事项

1. **赎回审核**: 用户赎回需要管理员审核，不是即时的
2. **流动性管理**: 管理员应确保合约有足够余额处理赎回
3. **奖励频率**: 建议定期存入奖励以更新兑换比例
4. **Gas 费用**: 批量操作可以节省 gas 费用
5. **价格滑点**: 大额赎回可能影响合约流动性

## 前端集成

推荐在前端展示：
1. 当前 APY（年化收益率）
2. 实时兑换比例
3. 用户 bXDC 余额及对应的 XDC 价值
4. 赎回请求状态
5. 合约总锁仓量（TVL）

## 许可证

MIT License
