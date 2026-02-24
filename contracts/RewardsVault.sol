// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RewardsVault
 * @dev Dedicated vault that ONLY receives validator rewards from XDCValidator (0x88).
 * Register this vault as the masternode owner/reward recipient.
 * Only the staking pool can pull rewards - prevents exchange rate manipulation.
 */
contract RewardsVault {
    address public constant VALIDATOR = 0x0000000000000000000000000000000000000088;
    address public stakingPool;

    event RewardsCollected(uint256 amount);
    event StakingPoolSet(address indexed stakingPool);

    constructor(address _stakingPool) {
        require(_stakingPool != address(0), "Invalid staking pool");
        stakingPool = _stakingPool;
        emit StakingPoolSet(_stakingPool);
    }

    /// @dev Only the staking pool can pull rewards - atomically updates totalPooledXDC
    function collectRewards() external returns (uint256) {
        require(msg.sender == stakingPool, "Only staking pool");
        uint256 amount = address(this).balance;
        if (amount > 0) {
            (bool ok, ) = payable(stakingPool).call{value: amount}("");
            require(ok, "Transfer failed");
            emit RewardsCollected(amount);
        }
        return amount;
    }

    receive() external payable {}
}
