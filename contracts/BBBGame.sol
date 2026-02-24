// SPDX-License-Identifier: MIT
pragma solidity =0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title BBBGame
 * @dev Game contract that allows BBBubu NFT holders to mine CAR points
 * Rules:
 * - BBBubu NFT holders can click to start mining once every 24 hours
 * - Base mining rate: 0.001 CAR per block (adjustable by owner)
 * - Holding multiple BBBubu NFTs increases mining multiplier
 * - Each click mines for 24 hours
 */
contract BBBGame is Ownable, ReentrancyGuard {
    // ============ CONSTANTS ============

    /// @notice Minimum click interval (24 hours in blocks)
    uint256 public constant MIN_CLICK_INTERVAL = 43200; // 24 * 60 * 60 / 2

    // ============ STATE VARIABLES ============

    /// @notice BBBubu NFT contract address
    address public bbbNftContract;

    /// @notice Base mining rate: CAR amount per block
    uint256 public baseMiningRate = 1e15; // Default 0.001 CAR per block

    /// @notice User CAR points balance
    mapping(address => uint256) public carPoints;

    /// @notice User mining information
    struct MiningInfo {
        uint256 lastClickBlock; // Last click block number
        uint256 miningStartBlock; // Mining start block number
        uint256 miningEndBlock; // Mining end block number
        uint256 nftCount; // NFT count when clicked
        uint256 accumulatedRewards; // Accumulated but unclaimed rewards
        bool isMining; // Whether currently mining
    }

    /// @notice User address => mining information
    mapping(address => MiningInfo) public userMiningInfo;

    // ============ EVENTS ============

    event MiningStarted(
        address indexed user,
        uint256 indexed startBlock,
        uint256 indexed endBlock,
        uint256 nftCount,
        uint256 miningRate
    );

    event CarPointsAwarded(address indexed user, uint256 amount);

    event BaseMiningRateUpdated(uint256 oldRate, uint256 newRate);

    // ============ CONSTRUCTOR ============

    constructor() Ownable(msg.sender) {
        bbbNftContract = 0x7601A8BA5a4f77c6Ef424E850bab68A5C8c0473D;
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Start mining (click to mine)
     * @dev Requires holding at least 1 BBBubu NFT and 24 hours since last click
     */
    function startMining() external nonReentrant {
        address user = msg.sender;

        // Check if user owns BBBubu NFTs
        uint256 nftBalance = IERC721(bbbNftContract).balanceOf(user);
        require(nftBalance > 0, "Must own at least 1 BBBubu NFT");

        MiningInfo storage userInfo = userMiningInfo[user];

        // Check click interval (24 hours)
        require(
            block.number >= userInfo.lastClickBlock + MIN_CLICK_INTERVAL,
            "Must wait 24h between clicks"
        );

        // If user was previously mining, claim pending rewards first
        if (userInfo.isMining) {
            _claimPendingRewards(user);
        }

        // Update mining information
        userInfo.lastClickBlock = block.number;
        userInfo.miningStartBlock = block.number;
        userInfo.miningEndBlock = block.number + MIN_CLICK_INTERVAL;
        userInfo.nftCount = nftBalance;
        userInfo.isMining = true;

        // Calculate mining rate (base rate * NFT count)
        uint256 miningRate = baseMiningRate * nftBalance;

        emit MiningStarted(
            user,
            userInfo.miningStartBlock,
            userInfo.miningEndBlock,
            nftBalance,
            miningRate
        );
    }

    /**
     * @notice Set base mining rate (owner only)
     * @param _newRate New base mining rate (CAR amount per block)
     */
    function setBaseMiningRate(uint256 _newRate) external onlyOwner {
        require(_newRate > 0, "Rate must be greater than 0");
        uint256 oldRate = baseMiningRate;
        baseMiningRate = _newRate;
        emit BaseMiningRateUpdated(oldRate, _newRate);
    }

    /**
     * @notice Get user current points and last click block
     * @param user User address
     * @return currentPoints Current total points (including pending)
     * @return lastClickBlock Last click block number
     * @return remainingBlocks Remaining blocks until next click (0 means can click)
     */
    function getUserInfo(
        address user
    )
        external
        view
        returns (
            uint256 currentPoints,
            uint256 lastClickBlock,
            uint256 remainingBlocks
        )
    {
        MiningInfo memory userInfo = userMiningInfo[user];
        currentPoints = _calculateTotalPoints(user);
        lastClickBlock = userInfo.lastClickBlock;

        // Calculate next click block number
        uint256 nextClickBlock = userInfo.lastClickBlock + MIN_CLICK_INTERVAL;

        // If current block reached or exceeded next click block, can click (0 remaining blocks)
        if (block.number >= nextClickBlock) {
            remainingBlocks = 0;
        } else {
            remainingBlocks = nextClickBlock - block.number;
        }
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Calculate user's current total points (including pending mining rewards)
     * @param user User address
     * @return Total points amount
     */
    function _calculateTotalPoints(
        address user
    ) internal view returns (uint256) {
        MiningInfo memory userInfo = userMiningInfo[user];
        uint256 totalPoints = carPoints[user];

        if (!userInfo.isMining) {
            return totalPoints + userInfo.accumulatedRewards;
        }

        // Calculate mining blocks
        uint256 currentBlock = block.number;
        uint256 endBlock = userInfo.miningEndBlock;

        // If current block exceeded mining end block, use end block
        if (currentBlock > endBlock) {
            currentBlock = endBlock;
        }

        uint256 miningBlocks = currentBlock - userInfo.miningStartBlock;
        uint256 miningRate = baseMiningRate * userInfo.nftCount;
        uint256 pendingRewards = miningBlocks * miningRate;

        return totalPoints + userInfo.accumulatedRewards + pendingRewards;
    }

    /**
     * @notice Claim user's pending rewards
     * @param user User address
     */
    function _claimPendingRewards(address user) internal {
        MiningInfo storage userInfo = userMiningInfo[user];

        if (!userInfo.isMining) {
            // Only accumulated rewards need to be claimed
            if (userInfo.accumulatedRewards > 0) {
                carPoints[user] += userInfo.accumulatedRewards;
                emit CarPointsAwarded(user, userInfo.accumulatedRewards);
                userInfo.accumulatedRewards = 0;
            }
            return;
        }

        // Calculate mining blocks
        uint256 currentBlock = block.number;
        uint256 endBlock = userInfo.miningEndBlock;

        // If current block exceeded mining end block, use end block and stop mining
        if (currentBlock > endBlock) {
            currentBlock = endBlock;
            userInfo.isMining = false;
        }

        uint256 miningBlocks = currentBlock - userInfo.miningStartBlock;
        uint256 miningRate = baseMiningRate * userInfo.nftCount;
        uint256 pendingRewards = miningBlocks * miningRate;
        uint256 totalRewards = userInfo.accumulatedRewards + pendingRewards;

        if (totalRewards > 0) {
            carPoints[user] += totalRewards;
            emit CarPointsAwarded(user, totalRewards);

            // Reset accumulated rewards and mining start block
            userInfo.accumulatedRewards = 0;
            if (userInfo.isMining) {
                userInfo.miningStartBlock = currentBlock;
            }
        }
    }
}
