// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title bpsXDC
 * @dev A wrapped version of XDC token using OpenZeppelin's ERC20Wrapper
 * with a 1% fee on withdrawals that accumulates in the contract
 */
contract bpsXDC is ERC20Wrapper, Ownable {
    // Fee percentage (1%)
    uint256 public constant FEE_PERCENTAGE = 1;

    // Accumulated fees
    uint256 public accumulatedFees;

    /**
     * @dev Constructor that sets up the wrapped token with a hardcoded XDC token address
     * and sets the deployer as the owner
     */
    constructor()
        ERC20("bpsXDC", "bpsXDC")
        ERC20Wrapper(
            IERC20(address(0x9B8e12b0BAC165B86967E771d98B520Ec3F665A6))
        )
        Ownable(msg.sender)
    {}

    /**
     * @dev Override withdrawTo to implement 1% fee
     * @param account Address to receive the unwrapped tokens
     * @param value Amount of wrapped tokens to burn
     */
    function withdrawTo(
        address account,
        uint256 value
    ) public virtual override returns (bool) {
        if (account == address(this)) {
            revert ERC20InvalidReceiver(account);
        }

        // Calculate fee (1% of the value)
        uint256 fee = (value * FEE_PERCENTAGE) / 100;
        uint256 amountAfterFee = value - fee;

        // Burn the wrapped tokens
        _burn(_msgSender(), value);

        // Transfer the underlying tokens after fee deduction to the user
        SafeERC20.safeTransfer(underlying(), account, amountAfterFee);

        // Accumulate the fee in the contract
        if (fee > 0) {
            accumulatedFees += fee;
        }

        return true;
    }

    /**
     * @dev Allows the owner to withdraw accumulated fees
     * @param recipient Address to receive the withdrawn fees
     * @param amount Amount of fees to withdraw (0 for all)
     */
    function withdrawFees(
        address recipient,
        uint256 amount
    ) external onlyOwner {
        require(
            recipient != address(0),
            "Cannot withdraw fees to zero address"
        );

        uint256 withdrawAmount = amount;
        if (amount == 0 || amount > accumulatedFees) {
            withdrawAmount = accumulatedFees;
        }

        require(withdrawAmount > 0, "No fees to withdraw");

        accumulatedFees -= withdrawAmount;
        SafeERC20.safeTransfer(underlying(), recipient, withdrawAmount);
    }

    /**
     * @dev Returns the current amount of accumulated fees
     */
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }
}
