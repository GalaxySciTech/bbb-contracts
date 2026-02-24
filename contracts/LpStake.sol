pragma solidity =0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract LpStake is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant PRECISION = 1e18; // Precision factor for calculations

    // Pool info struct
    struct PoolInfo {
        IERC20 lpToken; // LP token that users can stake
        IERC20 rewardToken; // Token given as reward
        uint256 lastRewardBlock; // Last block number rewards were distributed
        uint256 accRewardPerShare; // Accumulated rewards per share, multiplied by PRECISION
        uint256 totalStaked; // Total amount of LP tokens staked
        uint256 rewardPerBlock; // Reward tokens per block for this pool
        bool isActive; // Whether this pool is active
        uint256 startBlock; // Pool start block
        uint256 endBlock; // Pool end block (0 means no end)
    }

    // User info struct
    struct UserInfo {
        uint256 amount; // Amount of LP tokens staked
        uint256 rewardDebt; // Reward debt, multiplied by PRECISION
        uint256 pendingRewards; // Pending rewards
    }

    // State variables
    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // poolId => user address => UserInfo

    // Events
    event AddPool(
        uint256 indexed pid,
        address lpToken,
        address rewardToken,
        uint256 rewardPerBlock
    );
    event SetPoolStatus(uint256 indexed pid, bool isActive);
    event SetRewardPerBlock(uint256 indexed pid, uint256 rewardPerBlock);
    event Deposit(uint256 indexed pid, address indexed user, uint256 amount);
    event Withdraw(uint256 indexed pid, address indexed user, uint256 amount);
    event ClaimReward(
        uint256 indexed pid,
        address indexed user,
        uint256 amount
    );
    event EmergencyWithdraw(
        uint256 indexed pid,
        address indexed user,
        uint256 amount
    );

    // Modifiers
    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "Pool does not exist");
        require(poolInfo[_pid].isActive, "Pool is not active");
        _;
    }

    constructor() Ownable(msg.sender) {}

    // Pause/Unpause contract
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Add a new pool
    function addPool(
        address _lpToken,
        address _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _blockDuration // Duration in blocks (0 means no end)
    ) external onlyOwner {
        require(_lpToken != address(0), "Invalid LP token address");
        require(_rewardToken != address(0), "Invalid reward token address");
        require(_rewardPerBlock > 0, "Invalid reward per block");

        uint256 startBlock = block.number;
        uint256 endBlock = _blockDuration > 0 ? startBlock + _blockDuration : 0;

        poolInfo.push(
            PoolInfo({
                lpToken: IERC20(_lpToken),
                rewardToken: IERC20(_rewardToken),
                lastRewardBlock: startBlock,
                accRewardPerShare: 0,
                totalStaked: 0,
                rewardPerBlock: _rewardPerBlock,
                isActive: true,
                startBlock: startBlock,
                endBlock: endBlock
            })
        );

        emit AddPool(
            poolInfo.length - 1,
            _lpToken,
            _rewardToken,
            _rewardPerBlock
        );
    }

    // Set pool status (active/inactive)
    function setPoolStatus(uint256 _pid, bool _isActive) external onlyOwner {
        poolInfo[_pid].isActive = _isActive;
        emit SetPoolStatus(_pid, _isActive);
    }

    // Set reward per block for a pool
    function setRewardPerBlock(
        uint256 _pid,
        uint256 _rewardPerBlock
    ) external onlyOwner {
        require(_rewardPerBlock > 0, "Invalid reward per block");
        require(_pid < poolInfo.length, "Pool does not exist");

        updatePool(_pid);
        poolInfo[_pid].rewardPerBlock = _rewardPerBlock;
        emit SetRewardPerBlock(_pid, _rewardPerBlock);
    }

    // Update reward variables for a pool
    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];

        if (
            block.number <= pool.lastRewardBlock ||
            block.number < pool.startBlock
        ) {
            return;
        }

        // If end block is set and current block exceeds it, use end block for calculation
        uint256 endBlock = block.number;
        if (pool.endBlock > 0 && block.number > pool.endBlock) {
            endBlock = pool.endBlock;
        }

        if (pool.totalStaked == 0) {
            pool.lastRewardBlock = endBlock;
            return;
        }

        uint256 multiplier = endBlock - pool.lastRewardBlock;
        uint256 reward = multiplier * pool.rewardPerBlock;
        pool.accRewardPerShare =
            pool.accRewardPerShare +
            ((reward * PRECISION) / pool.totalStaked);
        pool.lastRewardBlock = endBlock;
    }

    // View function to see pending rewards
    function pendingReward(
        uint256 _pid,
        address _user
    ) external view validatePool(_pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;

        if (block.number > pool.lastRewardBlock && pool.totalStaked != 0) {
            uint256 endBlock = block.number;
            if (pool.endBlock > 0 && block.number > pool.endBlock) {
                endBlock = pool.endBlock;
            }
            uint256 multiplier = endBlock - pool.lastRewardBlock;
            uint256 reward = multiplier * pool.rewardPerBlock;
            accRewardPerShare =
                accRewardPerShare +
                ((reward * PRECISION) / pool.totalStaked);
        }

        return
            user.pendingRewards +
            ((user.amount * accRewardPerShare) / PRECISION) -
            user.rewardDebt;
    }

    // Stake LP tokens
    function deposit(
        uint256 _pid,
        uint256 _amount
    ) external nonReentrant whenNotPaused validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(block.number >= pool.startBlock, "Pool not started");
        require(
            pool.endBlock == 0 || block.number <= pool.endBlock,
            "Pool ended"
        );

        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = ((user.amount * pool.accRewardPerShare) /
                PRECISION) - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards = user.pendingRewards + pending;
            }
        }

        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            user.amount = user.amount + _amount;
            pool.totalStaked = pool.totalStaked + _amount;
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION;
        emit Deposit(_pid, msg.sender, _amount);
    }

    // Withdraw LP tokens
    function withdraw(
        uint256 _pid,
        uint256 _amount
    ) external nonReentrant whenNotPaused validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "Withdraw: insufficient balance");

        updatePool(_pid);

        uint256 pending = ((user.amount * pool.accRewardPerShare) / PRECISION) -
            user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards + pending;
        }

        if (_amount > 0) {
            user.amount = user.amount - _amount;
            pool.totalStaked = pool.totalStaked - _amount;
            pool.lpToken.safeTransfer(msg.sender, _amount);
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION;
        emit Withdraw(_pid, msg.sender, _amount);
    }

    // Claim accumulated rewards
    function claimReward(
        uint256 _pid
    ) external nonReentrant whenNotPaused validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = ((user.amount * pool.accRewardPerShare) / PRECISION) -
            user.rewardDebt;
        if (pending > 0 || user.pendingRewards > 0) {
            uint256 totalRewards = pending + user.pendingRewards;
            user.pendingRewards = 0;

            // Ensure contract has enough reward tokens
            require(
                pool.rewardToken.balanceOf(address(this)) >= totalRewards,
                "Insufficient reward token balance"
            );

            pool.rewardToken.safeTransfer(msg.sender, totalRewards);
            emit ClaimReward(_pid, msg.sender, totalRewards);
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION;
    }

    // Emergency withdraw without caring about rewards
    function emergencyWithdraw(
        uint256 _pid
    ) external nonReentrant validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;

        require(amount > 0, "No tokens to withdraw");

        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;
        pool.totalStaked = pool.totalStaked - amount;

        pool.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(_pid, msg.sender, amount);
    }

    // View function to get the number of pools
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Admin rescue function: withdraw accidentally sent tokens from contract
    function rescueTokens(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }
}
