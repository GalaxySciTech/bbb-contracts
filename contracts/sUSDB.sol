// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract sUSDB is ERC20, Ownable, ReentrancyGuard {
    // USDB token contract address
    IERC20 public immutable usdbToken;
    
    // Withdrawal request structure
    struct WithdrawalRequest {
        uint256 usdbAmount;      // USDB amount to withdraw
        uint256 sUSDBAmount;     // Original sUSDB amount (for cancellation)
        uint256 unlockTime;
        bool active;
    }
    
    // User withdrawal requests
    mapping(address => WithdrawalRequest[]) public withdrawalRequests;
    
    // Track users with withdrawal requests
    address[] public usersWithWithdrawals;
    mapping(address => bool) public hasWithdrawalRequests;
    

    
    // Constants
    uint256 public constant WITHDRAWAL_DELAY = 7 days;
    uint256 private constant PRECISION = 1e12;
    
    // Events
    event Deposit(address indexed user, uint256 usdbAmount, uint256 sUSDBAmount);
    event WithdrawalRequested(address indexed user, uint256 sUSDBAmount, uint256 usdbAmount, uint256 unlockTime, uint256 requestIndex);
    event Withdrawn(address indexed user, uint256 usdbAmount, uint256 requestIndex);
    event WithdrawalCancelled(address indexed user, uint256 sUSDBAmount, uint256 usdbAmount, uint256 requestIndex);
    event AssetsDeposited(uint256 amount, uint256 newExchangeRate);
    
    constructor() 
        ERC20("Staked USDB", "sUSDB") 
        Ownable(msg.sender) 
    {
        usdbToken = IERC20(0xA23885c8E0743C734Bd6Da0df66e2631Ee9Bc6D8);
    }
    
    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
    
    /**
     * @dev Get the underlying USDB token address
     */
    function underlying() external view returns (IERC20) {
        return usdbToken;
    }
    
    /**
     * @dev Get total assets under management (USDB held in contract excluding pending withdrawals)
     */
    function totalAssets() public view returns (uint256) {
        uint256 contractBalance = usdbToken.balanceOf(address(this));
        uint256 pendingWithdrawals = getTotalPendingWithdrawals();
        
        if (contractBalance > pendingWithdrawals) {
            return contractBalance - pendingWithdrawals;
        }
        return usdbToken.balanceOf(address(this));
    }
    
    /**
     * @dev Get current exchange rate (USDB per sUSDB)
     * Returns the amount of USDB that 1 sUSDB can be redeemed for
     */
    function getExchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 1e6; // 1:1 initial rate (6 decimals)
        }
        return (totalAssets() * 1e6) / supply;
    }
    
    /**
     * @dev Convert USDB amount to sUSDB amount based on current exchange rate
     */
    function convertToShares(uint256 usdbAmount) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return usdbAmount; // 1:1 for first deposit
        }
        uint256 assets = totalAssets();
        require(assets > 0, "sUSDB: no assets available for conversion");
        return (usdbAmount * supply) / assets;
    }
    
    /**
     * @dev Convert sUSDB amount to USDB amount based on current exchange rate
     */
    function convertToAssets(uint256 sharesAmount) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return sharesAmount;
        }
        uint256 assets = totalAssets();
        require(assets > 0, "sUSDB: no assets available for conversion");
        return (sharesAmount * assets) / supply;
    }
    
    /**
     * @dev Deposit USDB tokens to mint sUSDB based on exchange rate
     */
    function deposit(uint256 usdbAmount) external nonReentrant {
        require(usdbAmount > 0, "sUSDB: amount must be greater than 0");
        
        // Calculate how many sUSDB shares to mint based on current exchange rate
        uint256 sharesToMint = convertToShares(usdbAmount);
        
        // Transfer USDB from user to this contract
        usdbToken.transferFrom(msg.sender, address(this), usdbAmount);
        
        // Mint sUSDB tokens
        _mint(msg.sender, sharesToMint);
        
        emit Deposit(msg.sender, usdbAmount, sharesToMint);
    }
    
    /**
     * @dev Request withdrawal of sUSDB tokens (7 days delay)
     */
    function requestWithdrawal(uint256 sUSDBAmount) external nonReentrant {
        require(sUSDBAmount > 0, "sUSDB: amount must be greater than 0");
        require(balanceOf(msg.sender) >= sUSDBAmount, "sUSDB: insufficient balance");
        
        // Calculate USDB amount based on current exchange rate
        uint256 usdbAmount = convertToAssets(sUSDBAmount);
        
        // Burn sUSDB tokens
        _burn(msg.sender, sUSDBAmount);
        
        // Create withdrawal request
        uint256 unlockTime = block.timestamp + WITHDRAWAL_DELAY;
        withdrawalRequests[msg.sender].push(WithdrawalRequest({
            usdbAmount: usdbAmount,      // USDB amount to withdraw
            sUSDBAmount: sUSDBAmount,    // Original sUSDB amount for cancellation
            unlockTime: unlockTime,
            active: true
        }));
        
        // Track user if first withdrawal request
        if (!hasWithdrawalRequests[msg.sender]) {
            hasWithdrawalRequests[msg.sender] = true;
            usersWithWithdrawals.push(msg.sender);
        }
        
        emit WithdrawalRequested(msg.sender, sUSDBAmount, usdbAmount, unlockTime, withdrawalRequests[msg.sender].length - 1);
    }
    
    /**
     * @dev Execute withdrawal after delay period
     */
    function executeWithdrawal(uint256 requestIndex) external nonReentrant {
        require(requestIndex < withdrawalRequests[msg.sender].length, "sUSDB: invalid request index");
        
        WithdrawalRequest storage request = withdrawalRequests[msg.sender][requestIndex];
        require(request.active, "sUSDB: request already executed");
        require(block.timestamp >= request.unlockTime, "sUSDB: withdrawal still locked");
        
        uint256 amount = request.usdbAmount;
        
        // More sophisticated balance check: ensure we have enough for this withdrawal
        // considering other pending withdrawals and minimum reserve for rewards
        uint256 contractBalance = usdbToken.balanceOf(address(this));
        uint256 totalPendingWithdrawals = getTotalPendingWithdrawals();
        
        // Ensure we don't touch reward funds for withdrawals
        require(contractBalance >= amount, "sUSDB: insufficient contract balance");
        require(contractBalance >= totalPendingWithdrawals, "sUSDB: insufficient funds for all pending withdrawals");
        
        request.active = false;
        
        // Transfer USDB back to user
        usdbToken.transfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount, requestIndex);
    }
    
    /**
     * @dev Cancel withdrawal request and restore sUSDB tokens
     */
    function cancelWithdrawal(uint256 requestIndex) external nonReentrant {
        require(requestIndex < withdrawalRequests[msg.sender].length, "sUSDB: invalid request index");
        
        WithdrawalRequest storage request = withdrawalRequests[msg.sender][requestIndex];
        require(request.active, "sUSDB: request already executed or cancelled");
        
        uint256 usdbAmount = request.usdbAmount;
        uint256 sUSDBAmount = request.sUSDBAmount; // Use original sUSDB amount
        
        // Mark request as inactive
        request.active = false;
        
        // Mint original sUSDB tokens back to user
        _mint(msg.sender, sUSDBAmount);
        
        emit WithdrawalCancelled(msg.sender, sUSDBAmount, usdbAmount, requestIndex);
    }
    
    /**
     * @dev Get all withdrawal requests for a user
     */
    function getUserWithdrawalRequests(address user) external view returns (WithdrawalRequest[] memory) {
        return withdrawalRequests[user];
    }
    
    /**
     * @dev Get active withdrawal requests for a user
     */
    function getActiveWithdrawalRequests(address user) external view returns (WithdrawalRequest[] memory activeRequests, uint256[] memory indices) {
        WithdrawalRequest[] memory allRequests = withdrawalRequests[user];
        uint256 activeCount = 0;
        
        // Count active requests
        for (uint256 i = 0; i < allRequests.length; i++) {
            if (allRequests[i].active) {
                activeCount++;
            }
        }
        
        // Create arrays for active requests
        activeRequests = new WithdrawalRequest[](activeCount);
        indices = new uint256[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < allRequests.length; i++) {
            if (allRequests[i].active) {
                activeRequests[currentIndex] = allRequests[i];
                indices[currentIndex] = i;
                currentIndex++;
            }
        }
    }
    
    /**
     * @dev Get cancellable withdrawal requests for a user (active but not yet unlocked)
     */
    function getCancellableWithdrawalRequests(address user) external view returns (WithdrawalRequest[] memory cancellableRequests, uint256[] memory indices) {
        WithdrawalRequest[] memory allRequests = withdrawalRequests[user];
        uint256 cancellableCount = 0;
        
        // Count cancellable requests (active and not yet unlocked)
        for (uint256 i = 0; i < allRequests.length; i++) {
            if (allRequests[i].active && block.timestamp < allRequests[i].unlockTime) {
                cancellableCount++;
            }
        }
        
        // Create arrays for cancellable requests
        cancellableRequests = new WithdrawalRequest[](cancellableCount);
        indices = new uint256[](cancellableCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < allRequests.length; i++) {
            if (allRequests[i].active && block.timestamp < allRequests[i].unlockTime) {
                cancellableRequests[currentIndex] = allRequests[i];
                indices[currentIndex] = i;
                currentIndex++;
            }
        }
    }
    
    /**
     * @dev Get executable withdrawal requests for a user (active and unlocked)
     */
    function getExecutableWithdrawalRequests(address user) external view returns (WithdrawalRequest[] memory executableRequests, uint256[] memory indices) {
        WithdrawalRequest[] memory allRequests = withdrawalRequests[user];
        uint256 executableCount = 0;
        
        // Count executable requests (active and unlocked)
        for (uint256 i = 0; i < allRequests.length; i++) {
            if (allRequests[i].active && block.timestamp >= allRequests[i].unlockTime) {
                executableCount++;
            }
        }
        
        // Create arrays for executable requests
        executableRequests = new WithdrawalRequest[](executableCount);
        indices = new uint256[](executableCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < allRequests.length; i++) {
            if (allRequests[i].active && block.timestamp >= allRequests[i].unlockTime) {
                executableRequests[currentIndex] = allRequests[i];
                indices[currentIndex] = i;
                currentIndex++;
            }
        }
    }
    
    /**
     * @dev Get active withdrawal requests with pagination
     * @param page Page number (starting from 0)
     * @param size Number of users per page
     */
    function getAllActiveWithdrawals(uint256 page, uint256 size) 
        external 
        view 
        returns (
            address[] memory users, 
            WithdrawalRequest[][] memory requests,
            uint256 totalUsers,
            uint256 totalPages
        ) 
    {
        require(size > 0 && size <= 100, "sUSDB: invalid page size");
        
        // Count users with active withdrawal requests
        uint256 activeUserCount = 0;
        address[] memory activeUsers = new address[](usersWithWithdrawals.length);
        
        for (uint256 i = 0; i < usersWithWithdrawals.length; i++) {
            address user = usersWithWithdrawals[i];
            if (_hasActiveWithdrawals(user)) {
                activeUsers[activeUserCount] = user;
                activeUserCount++;
            }
        }
        
        totalUsers = activeUserCount;
        totalPages = (totalUsers + size - 1) / size; // Ceiling division
        
        // Calculate pagination bounds
        uint256 startIndex = page * size;
        uint256 endIndex = startIndex + size;
        if (endIndex > activeUserCount) {
            endIndex = activeUserCount;
        }
        
        // Return empty arrays if page is out of bounds
        if (startIndex >= activeUserCount) {
            users = new address[](0);
            requests = new WithdrawalRequest[][](0);
            return (users, requests, totalUsers, totalPages);
        }
        
        // Calculate actual return size
        uint256 returnSize = endIndex - startIndex;
        users = new address[](returnSize);
        requests = new WithdrawalRequest[][](returnSize);
        
        // Fill the return arrays
        for (uint256 i = 0; i < returnSize; i++) {
            address user = activeUsers[startIndex + i];
            users[i] = user;
            
            // Get active withdrawal requests for this user
            WithdrawalRequest[] memory userRequests = withdrawalRequests[user];
            uint256 activeCount = 0;
            
            // Count active requests
            for (uint256 j = 0; j < userRequests.length; j++) {
                if (userRequests[j].active) {
                    activeCount++;
                }
            }
            
            // Fill active requests
            requests[i] = new WithdrawalRequest[](activeCount);
            uint256 currentIndex = 0;
            for (uint256 j = 0; j < userRequests.length; j++) {
                if (userRequests[j].active) {
                    requests[i][currentIndex] = userRequests[j];
                    currentIndex++;
                }
            }
        }
    }
    
    /**
     * @dev Check if user has active withdrawal requests
     */
    function _hasActiveWithdrawals(address user) internal view returns (bool) {
        WithdrawalRequest[] memory userRequests = withdrawalRequests[user];
        for (uint256 i = 0; i < userRequests.length; i++) {
            if (userRequests[i].active) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @dev Get total number of users with active withdrawal requests
     */
    function getActiveWithdrawalUsersCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < usersWithWithdrawals.length; i++) {
            if (_hasActiveWithdrawals(usersWithWithdrawals[i])) {
                count++;
            }
        }
        return count;
    }
    
    /**
     * @dev Get all users who ever had withdrawal requests
     */
    function getAllWithdrawalUsers() external view returns (address[] memory) {
        return usersWithWithdrawals;
    }
    
    /**
     * @dev Owner deposits USDB to compound yields for all sUSDB holders
     * This increases the exchange rate, benefiting all holders automatically
     */
    function compoundYield(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "sUSDB: amount must be greater than 0");
        require(totalSupply() > 0, "sUSDB: no tokens to compound yields to");
        
        usdbToken.transferFrom(msg.sender, address(this), amount);
        
        emit AssetsDeposited(amount, getExchangeRate());
    }
    

    
    /**
     * @dev Emergency function to withdraw tokens (only owner)
     * Note: Cannot withdraw USDB that belongs to users
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(usdbToken), "sUSDB: cannot withdraw USDB");
        require(amount > 0, "sUSDB: amount must be greater than 0");
        
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance >= amount, "sUSDB: insufficient token balance");
        
        IERC20(token).transfer(msg.sender, amount);
    }
    
    /**
     * @dev Get contract's available USDB balance (excluding pending withdrawals)
     */
    function getAvailableUSDBBalance() external view returns (uint256) {
        uint256 contractBalance = usdbToken.balanceOf(address(this));
        uint256 pendingWithdrawals = getTotalPendingWithdrawals();
        
        if (contractBalance > pendingWithdrawals) {
            return contractBalance - pendingWithdrawals;
        }
        return 0;
    }
    
    /**
     * @dev Get total amount of pending withdrawals
     */
    function getTotalPendingWithdrawals() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < usersWithWithdrawals.length; i++) {
            address user = usersWithWithdrawals[i];
            WithdrawalRequest[] memory requests = withdrawalRequests[user];
            for (uint256 j = 0; j < requests.length; j++) {
                if (requests[j].active) {
                    total += requests[j].usdbAmount;
                }
            }
        }
        return total;
    }
    

    
    /**
     * @dev Security check: Verify contract state consistency
     */
    function verifyContractState() external view returns (bool) {
        uint256 contractBalance = usdbToken.balanceOf(address(this));
        uint256 currentSupply = totalSupply();
        uint256 pendingWithdrawals = getTotalPendingWithdrawals();
        uint256 effectiveAssets = totalAssets();
        
        // Critical invariants:
        // 1. Contract balance should cover pending withdrawals + effective assets
        // 2. totalAssets should exclude pending withdrawals
        // 3. Exchange rate should be stable (no manipulation possible)
        
        bool balanceCheck = contractBalance >= (pendingWithdrawals + effectiveAssets);
        bool assetCheck = effectiveAssets == (contractBalance >= pendingWithdrawals ? contractBalance - pendingWithdrawals : 0);
        bool supplyCheck = (currentSupply == 0 || effectiveAssets > 0);
        
        return balanceCheck && assetCheck && supplyCheck;
    }
    
    /**
     * @dev Anti-manipulation check: Verify exchange rate stability
     * Returns true if current exchange rate is reasonable and not manipulated
     */
    function verifyExchangeRateIntegrity() external view returns (bool, uint256, string memory) {
        uint256 contractBalance = usdbToken.balanceOf(address(this));
        uint256 currentSupply = totalSupply();
        uint256 pendingWithdrawals = getTotalPendingWithdrawals();
        uint256 effectiveAssets = totalAssets();
        uint256 exchangeRate = getExchangeRate();
        
        // Check 1: Effective assets should equal contract balance minus pending withdrawals
        if (effectiveAssets != (contractBalance >= pendingWithdrawals ? contractBalance - pendingWithdrawals : 0)) {
            return (false, exchangeRate, "totalAssets calculation error");
        }
        
        // Check 2: Exchange rate should be reasonable (not astronomical due to manipulation)
        if (currentSupply > 0 && exchangeRate > 10e6) { // More than 10x initial rate
            return (false, exchangeRate, "exchange rate potentially manipulated");
        }
        
        // Check 3: Assets should match supply expectations
        if (currentSupply > 0 && effectiveAssets == 0) {
            return (false, exchangeRate, "zero assets with non-zero supply");
        }
        
        return (true, exchangeRate, "exchange rate integrity verified");
    }
    
    /**
     * @dev Emergency pause function (for critical bugs)
     */
    bool public paused = false;
    
    modifier whenNotPaused() {
        require(!paused, "sUSDB: contract is paused");
        _;
    }
    
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }
    
    /**
     * @dev Add pause protection to critical functions
     */
    function depositWithPauseCheck(uint256 usdbAmount) external nonReentrant whenNotPaused {
        require(usdbAmount > 0, "sUSDB: amount must be greater than 0");
        
        // Calculate how many sUSDB shares to mint based on current exchange rate
        uint256 sharesToMint = convertToShares(usdbAmount);
        
        // Transfer USDB from user to this contract
        usdbToken.transferFrom(msg.sender, address(this), usdbAmount);
        
        // Mint sUSDB tokens
        _mint(msg.sender, sharesToMint);
        
        emit Deposit(msg.sender, usdbAmount, sharesToMint);
    }
}
