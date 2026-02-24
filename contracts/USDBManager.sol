// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IUSDB {
    function withdrawToken(address token, uint256 amount) external;
    function supportedTokens(address token) external view returns (bool);
    function isTokenSupported(address token) external view returns (bool);
}

interface IsUSDB {
    function compoundYield(uint256 amount) external;
    function usdbToken() external view returns (IERC20);
}

interface IDeFiProtocol {
    function deposit(address token, uint256 amount) external returns (uint256);
    function withdraw(address token, uint256 amount) external returns (uint256);
    function getBalance(address token, address user) external view returns (uint256);
    function getPendingRewards(address user) external view returns (uint256);
    function claimRewards() external returns (uint256);
}

/**
 * @title USDBManager
 * @dev 自动化投资管理合约，管理USDB资金的投资和收益分配
 */
contract USDBManager is Ownable, ReentrancyGuard, Pausable {
    // 合约地址
    IUSDB public immutable usdbContract;
    IsUSDB public immutable susdbContract;
    IERC20 public immutable usdbToken;
    
    // 投资策略结构
    struct InvestmentStrategy {
        address protocol;           // 协议地址
        address token;             // 投资代币地址
        uint256 allocatedAmount;   // 已分配金额
        uint256 targetPercentage;  // 目标分配比例 (basis points, 10000 = 100%)
        bool active;               // 是否激活
        uint256 lastRebalance;     // 上次再平衡时间
        string description;        // 策略描述
    }
    
    // 投资记录结构
    struct InvestmentRecord {
        uint256 timestamp;
        address protocol;
        address token;
        uint256 amount;
        string action; // "invest", "withdraw", "rebalance", "claim"
        uint256 balanceBefore;
        uint256 balanceAfter;
    }
    
    // 持仓信息结构
    struct PositionInfo {
        address protocol;
        address token;
        uint256 amount;
        uint256 value;
        uint256 pendingRewards;
        uint256 lastUpdate;
    }
    
    // 状态变量
    mapping(uint256 => InvestmentStrategy) public strategies;
    mapping(address => bool) public authorizedProtocols;
    mapping(address => bool) public managers;
    
    InvestmentRecord[] public investmentHistory;
    uint256 public nextStrategyId;
    uint256 public totalInvestedAmount;
    uint256 public totalProfitGenerated;
    uint256 public lastRebalanceTime;
    uint256 public rebalanceInterval = 1 days;
    uint256 public maxSlippageBps = 300; // 3% 最大滑点
    
    // 事件
    event StrategyAdded(uint256 indexed strategyId, address protocol, address token, uint256 targetPercentage);
    event StrategyUpdated(uint256 indexed strategyId, uint256 newTargetPercentage, bool active);
    event InvestmentMade(address indexed protocol, address token, uint256 amount, uint256 strategyId);
    event WithdrawalMade(address indexed protocol, address token, uint256 amount, uint256 strategyId);
    event ProfitCompounded(uint256 amount, uint256 totalProfit);
    event RebalanceExecuted(uint256 timestamp, uint256 strategiesCount);
    event ManagerAdded(address manager);
    event ManagerRemoved(address manager);
    event ProtocolAuthorized(address protocol);
    event ProtocolDeauthorized(address protocol);
    event EmergencyWithdrawal(address token, uint256 amount);
    
    // 修饰符
    modifier onlyManager() {
        require(managers[msg.sender] || msg.sender == owner(), "USDBManager: not authorized manager");
        _;
    }
    
    modifier validStrategy(uint256 strategyId) {
        require(strategyId < nextStrategyId, "USDBManager: invalid strategy ID");
        require(strategies[strategyId].active, "USDBManager: strategy not active");
        _;
    }
    
    constructor(
        address _usdbContract,
        address _susdbContract
    ) Ownable(msg.sender) {
        require(_usdbContract != address(0), "USDBManager: invalid USDB contract");
        require(_susdbContract != address(0), "USDBManager: invalid sUSDB contract");
        
        usdbContract = IUSDB(_usdbContract);
        susdbContract = IsUSDB(_susdbContract);
        usdbToken = susdbContract.usdbToken();
        
        managers[msg.sender] = true;
        emit ManagerAdded(msg.sender);
    }
    
    /**
     * @dev 添加投资策略
     */
    function addStrategy(
        address protocol,
        address token,
        uint256 targetPercentage,
        string memory description
    ) external onlyOwner {
        require(protocol != address(0), "USDBManager: invalid protocol");
        require(token != address(0), "USDBManager: invalid token");
        require(targetPercentage <= 10000, "USDBManager: percentage too high");
        require(authorizedProtocols[protocol], "USDBManager: protocol not authorized");
        require(usdbContract.isTokenSupported(token), "USDBManager: token not supported by USDB");
        
        uint256 strategyId = nextStrategyId++;
        strategies[strategyId] = InvestmentStrategy({
            protocol: protocol,
            token: token,
            allocatedAmount: 0,
            targetPercentage: targetPercentage,
            active: true,
            lastRebalance: block.timestamp,
            description: description
        });
        
        emit StrategyAdded(strategyId, protocol, token, targetPercentage);
    }
    
    /**
     * @dev 更新投资策略
     */
    function updateStrategy(
        uint256 strategyId,
        uint256 newTargetPercentage,
        bool active
    ) external onlyOwner {
        require(strategyId < nextStrategyId, "USDBManager: invalid strategy ID");
        require(newTargetPercentage <= 10000, "USDBManager: percentage too high");
        
        strategies[strategyId].targetPercentage = newTargetPercentage;
        strategies[strategyId].active = active;
        
        emit StrategyUpdated(strategyId, newTargetPercentage, active);
    }
    
    /**
     * @dev 授权DeFi协议
     */
    function authorizeProtocol(address protocol) external onlyOwner {
        require(protocol != address(0), "USDBManager: invalid protocol");
        authorizedProtocols[protocol] = true;
        emit ProtocolAuthorized(protocol);
    }
    
    /**
     * @dev 取消授权DeFi协议
     */
    function deauthorizeProtocol(address protocol) external onlyOwner {
        authorizedProtocols[protocol] = false;
        emit ProtocolDeauthorized(protocol);
    }
    
    /**
     * @dev 添加管理员
     */
    function addManager(address manager) external onlyOwner {
        require(manager != address(0), "USDBManager: invalid manager");
        managers[manager] = true;
        emit ManagerAdded(manager);
    }
    
    /**
     * @dev 移除管理员
     */
    function removeManager(address manager) external onlyOwner {
        managers[manager] = false;
        emit ManagerRemoved(manager);
    }
    
    /**
     * @dev 执行投资操作
     */
    function invest(
        uint256 strategyId,
        uint256 amount
    ) external onlyManager nonReentrant whenNotPaused validStrategy(strategyId) {
        require(amount > 0, "USDBManager: amount must be greater than 0");
        
        InvestmentStrategy storage strategy = strategies[strategyId];
        
        // 从USDB合约提取资金
        uint256 balanceBefore = IERC20(strategy.token).balanceOf(address(this));
        usdbContract.withdrawToken(strategy.token, amount);
        uint256 balanceAfter = IERC20(strategy.token).balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;
        
        require(actualAmount > 0, "USDBManager: no tokens received");
        
        // 批准协议使用代币
        IERC20(strategy.token).approve(strategy.protocol, actualAmount);
        
        // 投资到协议
        IDeFiProtocol(strategy.protocol).deposit(strategy.token, actualAmount);
        
        // 更新策略状态
        strategy.allocatedAmount += actualAmount;
        totalInvestedAmount += actualAmount;
        
        // 记录投资历史
        _recordInvestment(strategy.protocol, strategy.token, actualAmount, "invest", balanceBefore, balanceAfter);
        
        emit InvestmentMade(strategy.protocol, strategy.token, actualAmount, strategyId);
    }
    
    /**
     * @dev 从协议提取资金
     */
    function withdraw(
        uint256 strategyId,
        uint256 amount
    ) external onlyManager nonReentrant whenNotPaused validStrategy(strategyId) {
        require(amount > 0, "USDBManager: amount must be greater than 0");
        
        InvestmentStrategy storage strategy = strategies[strategyId];
        require(strategy.allocatedAmount >= amount, "USDBManager: insufficient allocated amount");
        
        uint256 balanceBefore = IERC20(strategy.token).balanceOf(address(this));
        
        // 从协议提取资金
        IDeFiProtocol(strategy.protocol).withdraw(strategy.token, amount);
        
        uint256 balanceAfter = IERC20(strategy.token).balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;
        
        // 更新策略状态
        if (actualAmount <= strategy.allocatedAmount) {
            strategy.allocatedAmount -= actualAmount;
            totalInvestedAmount -= actualAmount;
        } else {
            // 如果提取的金额大于分配金额，说明有收益
            uint256 profit = actualAmount - strategy.allocatedAmount;
            totalProfitGenerated += profit;
            totalInvestedAmount -= strategy.allocatedAmount;
            strategy.allocatedAmount = 0;
        }
        
        // 记录提取历史
        _recordInvestment(strategy.protocol, strategy.token, actualAmount, "withdraw", balanceBefore, balanceAfter);
        
        emit WithdrawalMade(strategy.protocol, strategy.token, actualAmount, strategyId);
    }
    
    /**
     * @dev 收取所有策略的收益并复投到sUSDB
     */
    function harvestAndCompound() external onlyManager nonReentrant whenNotPaused {
        uint256 totalProfit = 0;
        
        // 遍历所有活跃策略收取收益
        for (uint256 i = 0; i < nextStrategyId; i++) {
            if (strategies[i].active) {
                InvestmentStrategy storage strategy = strategies[i];
                
                // 检查是否有待收取的奖励
                uint256 pendingRewards = IDeFiProtocol(strategy.protocol).getPendingRewards(address(this));
                if (pendingRewards > 0) {
                    uint256 balanceBefore = IERC20(strategy.token).balanceOf(address(this));
                    
                    // 收取奖励
                    IDeFiProtocol(strategy.protocol).claimRewards();
                    
                    uint256 balanceAfter = IERC20(strategy.token).balanceOf(address(this));
                    uint256 rewards = balanceAfter - balanceBefore;
                    
                    totalProfit += rewards;
                    
                    // 记录收益历史
                    _recordInvestment(strategy.protocol, strategy.token, rewards, "claim", balanceBefore, balanceAfter);
                }
            }
        }
        
        // 如果有收益，充入sUSDB合约
        if (totalProfit > 0) {
            _compoundProfit(totalProfit);
        }
    }
    
    /**
     * @dev 执行策略再平衡
     */
    function rebalance() external onlyManager nonReentrant whenNotPaused {
        require(
            block.timestamp >= lastRebalanceTime + rebalanceInterval,
            "USDBManager: rebalance too frequent"
        );
        
        // 计算总价值和每个策略的目标分配
        uint256 totalValue = getTotalPortfolioValue();
        uint256 activeStrategiesCount = 0;
        
        for (uint256 i = 0; i < nextStrategyId; i++) {
            if (strategies[i].active) {
                activeStrategiesCount++;
                InvestmentStrategy storage strategy = strategies[i];
                
                // 计算目标分配金额
                uint256 targetAmount = (totalValue * strategy.targetPercentage) / 10000;
                uint256 currentAmount = strategy.allocatedAmount;
                
                // 如果需要调整分配
                if (targetAmount > currentAmount) {
                    // 需要增加投资
                    uint256 difference = targetAmount - currentAmount;
                    if (difference > 0) {
                        _rebalanceInvest(i, difference);
                    }
                } else if (currentAmount > targetAmount) {
                    // 需要减少投资
                    uint256 difference = currentAmount - targetAmount;
                    if (difference > 0) {
                        _rebalanceWithdraw(i, difference);
                    }
                }
                
                strategy.lastRebalance = block.timestamp;
            }
        }
        
        lastRebalanceTime = block.timestamp;
        emit RebalanceExecuted(block.timestamp, activeStrategiesCount);
    }
    
    /**
     * @dev 获取所有持仓信息
     */
    function getAllPositions() external view returns (PositionInfo[] memory) {
        uint256 activeCount = 0;
        
        // 计算活跃策略数量
        for (uint256 i = 0; i < nextStrategyId; i++) {
            if (strategies[i].active) {
                activeCount++;
            }
        }
        
        PositionInfo[] memory positions = new PositionInfo[](activeCount);
        uint256 index = 0;
        
        // 填充持仓信息
        for (uint256 i = 0; i < nextStrategyId; i++) {
            if (strategies[i].active) {
                InvestmentStrategy storage strategy = strategies[i];
                
                uint256 protocolBalance = IDeFiProtocol(strategy.protocol).getBalance(
                    strategy.token,
                    address(this)
                );
                uint256 pendingRewards = IDeFiProtocol(strategy.protocol).getPendingRewards(address(this));
                
                positions[index] = PositionInfo({
                    protocol: strategy.protocol,
                    token: strategy.token,
                    amount: protocolBalance,
                    value: protocolBalance, // 简化处理，实际应该用价格预言机
                    pendingRewards: pendingRewards,
                    lastUpdate: block.timestamp
                });
                index++;
            }
        }
        
        return positions;
    }
    
    /**
     * @dev 获取总投资组合价值
     */
    function getTotalPortfolioValue() public view returns (uint256) {
        uint256 totalValue = 0;
        
        for (uint256 i = 0; i < nextStrategyId; i++) {
            if (strategies[i].active) {
                InvestmentStrategy storage strategy = strategies[i];
                uint256 protocolBalance = IDeFiProtocol(strategy.protocol).getBalance(
                    strategy.token,
                    address(this)
                );
                totalValue += protocolBalance;
            }
        }
        
        return totalValue;
    }
    
    /**
     * @dev 获取投资历史记录
     */
    function getInvestmentHistory(
        uint256 from,
        uint256 to
    ) external view returns (InvestmentRecord[] memory) {
        require(from <= to, "USDBManager: invalid range");
        require(to < investmentHistory.length, "USDBManager: index out of bounds");
        
        uint256 length = to - from + 1;
        InvestmentRecord[] memory records = new InvestmentRecord[](length);
        
        for (uint256 i = 0; i < length; i++) {
            records[i] = investmentHistory[from + i];
        }
        
        return records;
    }
    
    /**
     * @dev 获取策略详情
     */
    function getStrategy(uint256 strategyId) external view returns (InvestmentStrategy memory) {
        require(strategyId < nextStrategyId, "USDBManager: invalid strategy ID");
        return strategies[strategyId];
    }
    
    /**
     * @dev 获取活跃策略数量
     */
    function getActiveStrategiesCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < nextStrategyId; i++) {
            if (strategies[i].active) {
                count++;
            }
        }
        return count;
    }
    
    /**
     * @dev 设置再平衡间隔
     */
    function setRebalanceInterval(uint256 interval) external onlyOwner {
        require(interval >= 1 hours, "USDBManager: interval too short");
        rebalanceInterval = interval;
    }
    
    /**
     * @dev 设置最大滑点
     */
    function setMaxSlippage(uint256 slippageBps) external onlyOwner {
        require(slippageBps <= 1000, "USDBManager: slippage too high"); // 最大10%
        maxSlippageBps = slippageBps;
    }
    
    /**
     * @dev 紧急暂停功能
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev 恢复合约功能
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev 紧急提取功能（只能提取非投资资金）
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "USDBManager: invalid token");
        require(amount > 0, "USDBManager: amount must be greater than 0");
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amount, "USDBManager: insufficient balance");
        
        IERC20(token).transfer(owner(), amount);
        emit EmergencyWithdrawal(token, amount);
    }
    
    // 内部函数
    
    /**
     * @dev 记录投资历史
     */
    function _recordInvestment(
        address protocol,
        address token,
        uint256 amount,
        string memory action,
        uint256 balanceBefore,
        uint256 balanceAfter
    ) internal {
        investmentHistory.push(InvestmentRecord({
            timestamp: block.timestamp,
            protocol: protocol,
            token: token,
            amount: amount,
            action: action,
            balanceBefore: balanceBefore,
            balanceAfter: balanceAfter
        }));
    }
    
    /**
     * @dev 复投利润到sUSDB
     */
    function _compoundProfit(uint256 profit) internal {
        // 批准sUSDB合约使用USDB代币
        usdbToken.approve(address(susdbContract), profit);
        
        // 复投到sUSDB合约
        susdbContract.compoundYield(profit);
        
        totalProfitGenerated += profit;
        emit ProfitCompounded(profit, totalProfitGenerated);
    }
    
    /**
     * @dev 再平衡时增加投资
     */
    function _rebalanceInvest(uint256 strategyId, uint256 amount) internal {
        InvestmentStrategy storage strategy = strategies[strategyId];
        
        // 检查是否有足够的资金可用
        uint256 availableBalance = IERC20(strategy.token).balanceOf(address(this));
        if (availableBalance < amount) {
            // 从USDB提取不足的资金
            usdbContract.withdrawToken(strategy.token, amount - availableBalance);
        }
        
        // 投资到协议
        IERC20(strategy.token).approve(strategy.protocol, amount);
        IDeFiProtocol(strategy.protocol).deposit(strategy.token, amount);
        
        strategy.allocatedAmount += amount;
        totalInvestedAmount += amount;
        
        _recordInvestment(strategy.protocol, strategy.token, amount, "rebalance", 0, 0);
    }
    
    /**
     * @dev 再平衡时提取投资
     */
    function _rebalanceWithdraw(uint256 strategyId, uint256 amount) internal {
        InvestmentStrategy storage strategy = strategies[strategyId];
        
        // 从协议提取资金
        IDeFiProtocol(strategy.protocol).withdraw(strategy.token, amount);
        
        if (amount <= strategy.allocatedAmount) {
            strategy.allocatedAmount -= amount;
            totalInvestedAmount -= amount;
        } else {
            totalInvestedAmount -= strategy.allocatedAmount;
            strategy.allocatedAmount = 0;
        }
        
        _recordInvestment(strategy.protocol, strategy.token, amount, "rebalance", 0, 0);
    }
}





