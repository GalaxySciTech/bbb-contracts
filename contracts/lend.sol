// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LendingProtocol
 * @dev AAVE V3-inspired decentralized lending protocol with Ray Math and normalized balances
 * @author Your Team
 */
contract LendingProtocol is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ============ Constants ============
    uint256 public constant RAY = 1e27; // Ray precision (AAVE standard)
    uint256 public constant HALF_RAY = RAY / 2;
    uint256 public constant WAD = 1e18; // Wad precision
    uint256 public constant HALF_WAD = WAD / 2;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant LIQUIDATION_CLOSE_FACTOR_HF_THRESHOLD = 0.95e18; // Health factor threshold for 100% liquidation
    uint256 public constant DEFAULT_LIQUIDATION_THRESHOLD = 8500; // 85%
    uint256 public constant DEFAULT_LIQUIDATION_BONUS = 500; // 5%
    uint256 public constant DEFAULT_MAX_LTV = 7500; // 75%
    uint256 public constant BASIS_POINTS_FACTOR = 10000; // 100% = 10000 basis points
    uint256 public constant MIN_HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18; // 1.0

    // ============ Structs ============
    
    /**
     * @dev Reserve data structure (similar to AAVE)
     */
    struct ReserveData {
        // Configuration
        bool isActive;
        bool isFrozen;
        bool canBeCollateral;
        bool canBeBorrowed;
        
        // Interest rate data
        uint256 liquidityIndex; // Cumulative liquidity interest (Ray)
        uint256 variableBorrowIndex; // Cumulative variable borrow interest (Ray)
        uint256 currentVariableBorrowRate; // Current variable borrow rate (Ray)
        
        // Reserve state
        uint256 scaledTotalSupply; // Total supply in normalized form
        uint256 scaledTotalVariableDebt; // Total variable debt in normalized form
        uint256 lastUpdateTimestamp; // Last time indices were updated
        
        // Asset configuration
        uint256 decimals;
        uint256 ltv; // Loan-to-value ratio (basis points)
        uint256 liquidationThreshold; // Liquidation threshold (basis points)
        uint256 liquidationBonus; // Liquidation bonus (basis points)
        
        // Risk management
        uint256 supplyCap; // Maximum supply allowed
        uint256 borrowCap; // Maximum borrow allowed
        
        // Bad debt tracking
        uint256 accruedToTreasury; // Accrued to treasury
        uint256 deficit; // Bad debt amount
    }

    /**
     * @dev User data structure
     */
    struct UserData {
        mapping(address => uint256) scaledBalance; // Scaled supply balance
        mapping(address => uint256) scaledVariableDebt; // Scaled variable debt
        mapping(address => bool) usageAsCollateralEnabled; // Whether asset is used as collateral
    }

    /**
     * @dev Liquidation parameters
     */
    struct LiquidationParams {
        address collateralAsset;
        address debtAsset;
        address user;
        uint256 debtToCover;
        bool receiveAToken;
    }

    /**
     * @dev Interest Rate Model parameters (similar to Compound/AAVE)
     */
    struct InterestRateModel {
        uint256 baseRatePerYear;        // Base interest rate (Ray format)
        uint256 multiplierPerYear;      // Slope 1 - rate increase before kink (Ray format)  
        uint256 jumpMultiplierPerYear;  // Slope 2 - rate increase after kink (Ray format)
        uint256 kink;                   // Optimal utilization rate (Ray format)
    }

    // ============ State Variables ============
    
    // List of supported assets
    address[] public reservesList;
    
    // Asset address => Reserve data
    mapping(address => ReserveData) public reserves;
    
    // User address => User data
    mapping(address => UserData) internal users;
    
    // Price oracle
    mapping(address => uint256) public assetPrices; // Asset prices (USD, 18 decimal precision)
    
    // Configuration
    uint256 public maxNumberOfReserves = 128;
    uint256 public protocolFeeRate = 3000; // 30% (basis points)
    
    // Bad debt management
    mapping(address => uint256) public protocolReserves;
    
    // Interest rate models for each asset
    mapping(address => InterestRateModel) public interestRateModels;

    // ============ Events ============
    
    event ReserveDataUpdated(
        address indexed reserve,
        uint256 liquidityRate,
        uint256 variableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex
    );
    
    event Supply(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint16 indexed referralCode
    );
    
    event Withdraw(
        address indexed reserve,
        address indexed user,
        address indexed to,
        uint256 amount
    );
    
    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint16 indexed referralCode
    );
    
    event Repay(
        address indexed reserve,
        address indexed user,
        address indexed repayer,
        uint256 amount
    );
    
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator,
        bool receiveAToken
    );
    
    event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);
    event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);
    
    event PriceUpdated(address indexed asset, uint256 price);

    event TreasuryWithdraw(address indexed asset, uint256 amount, address indexed to);
    
    event ProtocolFeeRateUpdated(uint256 oldRate, uint256 newRate);

    // ============ Modifiers ============
    
    modifier onlyValidReserve(address asset) {
        require(reserves[asset].isActive, "Reserve not active");
        _;
    }

    modifier onlyActiveTrueFrozenFalse(address asset) {
        require(reserves[asset].isActive, "Reserve not active");
        require(!reserves[asset].isFrozen, "Reserve frozen");
        _;
    }

    // ============ Constructor ============
    
    constructor() Ownable(msg.sender) {
        // Initialize with RAY precision
    }

    // ============ Ray Math Library ============
    
    /**
     * @dev Multiplies two ray values
     */
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) {
            return 0;
        }
        require(a <= (type(uint256).max - HALF_RAY) / b, "Ray multiplication overflow");
        return (a * b + HALF_RAY) / RAY;
    }

    /**
     * @dev Divides two ray values
     */
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "Division by zero");
        uint256 halfB = b / 2;
        require(a <= (type(uint256).max - halfB) / RAY, "Ray division overflow");
        return (a * RAY + halfB) / b;
    }

    /**
     * @dev Converts WAD to RAY
     */
    function wadToRay(uint256 a) internal pure returns (uint256) {
        uint256 result = a * (RAY / WAD);
        require(result / (RAY / WAD) == a, "WAD to RAY overflow");
        return result;
    }

    /**
     * @dev Converts RAY to WAD
     */
    function rayToWad(uint256 a) internal pure returns (uint256) {
        uint256 halfRatio = (RAY / WAD) / 2;
        return (a + halfRatio) / (RAY / WAD);
    }

    // ============ Interest Rate Calculations ============
    
    /**
     * @dev Calculates compound interest using Taylor series approximation
     * @param rate The interest rate (in ray)
     * @param lastUpdateTimestamp The timestamp of the last update
     * @return The compound interest rate (in ray)
     */
    function calculateCompoundedInterest(
        uint256 rate,
        uint256 lastUpdateTimestamp
    ) public view returns (uint256) {
        uint256 exp = block.timestamp - lastUpdateTimestamp;
        if (exp == 0) {
            return RAY;
        }
        
        uint256 expMinusOne = exp - 1;
        uint256 expMinusTwo = exp > 2 ? exp - 2 : 0;
        
        uint256 ratePerSecond = rate / SECONDS_PER_YEAR;
        
        uint256 basePowerTwo = rayMul(ratePerSecond, ratePerSecond);
        uint256 basePowerThree = rayMul(basePowerTwo, ratePerSecond);
        
        uint256 secondTerm = (exp * expMinusOne * basePowerTwo) / 2;
        uint256 thirdTerm = (exp * expMinusOne * expMinusTwo * basePowerThree) / 6;
        
        return RAY + (ratePerSecond * exp) + secondTerm + thirdTerm;
    }

    /**
     * @dev Updates the liquidity cumulative index and variable borrow index
     * @param reserve The reserve object
     */
    function updateState(ReserveData storage reserve, address asset) internal {
        uint256 scaledVariableDebt = reserve.scaledTotalVariableDebt;
        uint256 previousVariableBorrowIndex = reserve.variableBorrowIndex;
        uint256 previousLiquidityIndex = reserve.liquidityIndex;
        uint256 newLiquidityIndex = previousLiquidityIndex;
        uint256 newVariableBorrowIndex = previousVariableBorrowIndex;

        // Update to dynamic interest rate
        uint256 newVariableBorrowRate = calculateCurrentVariableBorrowRate(asset);
        reserve.currentVariableBorrowRate = newVariableBorrowRate;

        if (scaledVariableDebt != 0) {
            uint256 cumulatedVariableBorrowInterest = calculateCompoundedInterest(
                reserve.currentVariableBorrowRate,
                reserve.lastUpdateTimestamp
            );
            newVariableBorrowIndex = rayMul(previousVariableBorrowIndex, cumulatedVariableBorrowInterest);
            reserve.variableBorrowIndex = newVariableBorrowIndex;

            uint256 totalDebt = rayMul(scaledVariableDebt, newVariableBorrowIndex);
            uint256 newTotalDebt = rayMul(scaledVariableDebt, previousVariableBorrowIndex);
            uint256 debtIncrease = totalDebt - newTotalDebt;

            uint256 protocolFee = rayMul(debtIncrease, wadToRay(protocolFeeRate * 1e14)); // Convert basis points to ray
            
            if (protocolFee != 0) {
                reserve.accruedToTreasury += rayDiv(protocolFee, newLiquidityIndex);
            }

            if (reserve.scaledTotalSupply != 0) {
                uint256 liquidityIncrease = debtIncrease - protocolFee;
                uint256 cumulatedLiquidityInterest = rayDiv(liquidityIncrease, reserve.scaledTotalSupply) + RAY;
                newLiquidityIndex = rayMul(previousLiquidityIndex, cumulatedLiquidityInterest);
                reserve.liquidityIndex = newLiquidityIndex;
            }
        }

        reserve.lastUpdateTimestamp = uint40(block.timestamp);

        emit ReserveDataUpdated(
            asset,
            0, // No longer using fixed liquidity rate
            newVariableBorrowRate,
            newLiquidityIndex,
            newVariableBorrowIndex
        );
    }

    // ============ Core Functions ============

    /**
     * @dev Initializes a reserve
     */
    function initReserve(
        address asset,
        bool canBeCollateral,
        bool canBeBorrowed,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 supplyCap,
        uint256 borrowCap
    ) external onlyOwner {
        require(asset != address(0), "Invalid asset address");
        require(!reserves[asset].isActive, "Reserve already initialized");
        require(reservesList.length < maxNumberOfReserves, "Max reserves exceeded");
        
        uint256 decimals = IERC20Metadata(asset).decimals();
        
        reserves[asset] = ReserveData({
            isActive: true,
            isFrozen: false,
            canBeCollateral: canBeCollateral,
            canBeBorrowed: canBeBorrowed,
            liquidityIndex: RAY,
            variableBorrowIndex: RAY,
            currentVariableBorrowRate: 0, // Will be set by interest rate model
            scaledTotalSupply: 0,
            scaledTotalVariableDebt: 0,
            lastUpdateTimestamp: uint40(block.timestamp),
            decimals: decimals,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus,
            supplyCap: supplyCap,
            borrowCap: borrowCap,
            accruedToTreasury: 0,
            deficit: 0
        });
        
        // Set default interest rate model (AAVE Volatile Assets parameters)
        // Base rate: 0%, Slope1: 12%, Slope2: 300%, Kink: 45%
        // 100% utilization = 0% + (45% × 12%) + (55% × 300%) = 170.4%
        interestRateModels[asset] = InterestRateModel({
            baseRatePerYear: 0,                                    // 0%
            multiplierPerYear: 120000000000000000000000000,        // 12% (0.12 * 1e27)
            jumpMultiplierPerYear: 3000000000000000000000000000,   // 300% (3.0 * 1e27)
            kink: 450000000000000000000000000                     // 45% (0.45 * 1e27)
        });
        
        reservesList.push(asset);
    }

    /**
     * @dev Supplies an asset to the protocol
     * @param asset The address of the underlying asset to supply
     * @param amount The amount to be supplied
     * @param onBehalfOf The address that will receive the aTokens
     * @param referralCode Code used to register the integrator originating the operation
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external nonReentrant onlyActiveTrueFrozenFalse(asset) {
        require(amount > 0, "Amount must be greater than 0");
        
        ReserveData storage reserve = reserves[asset];
        UserData storage userData = users[onBehalfOf];
        
        updateState(reserve, asset);
        
        uint256 currentBalance = userData.scaledBalance[asset];
        bool isFirstSupply = (currentBalance == 0);
        
        uint256 amountScaled = rayDiv(amount, reserve.liquidityIndex);
        require(amountScaled > 0, "Amount too small");
        
        reserve.scaledTotalSupply += amountScaled;
        userData.scaledBalance[asset] = currentBalance + amountScaled;
        
        if (isFirstSupply && reserve.canBeCollateral) {
            userData.usageAsCollateralEnabled[asset] = true;
            emit ReserveUsedAsCollateralEnabled(asset, onBehalfOf);
        }
        
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        
        emit Supply(asset, msg.sender, onBehalfOf, amount, referralCode);
    }

    /**
     * @dev Withdraws an asset from the protocol
     * @param asset The address of the underlying asset to withdraw
     * @param amount The amount to be withdrawn (use type(uint256).max to withdraw all)
     * @param to Address that will receive the underlying
     * @return The final amount withdrawn
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external nonReentrant onlyActiveTrueFrozenFalse(asset) returns (uint256) {
        require(amount > 0, "Amount must be greater than 0");
        
        ReserveData storage reserve = reserves[asset];
        UserData storage userData = users[msg.sender];
        
        updateState(reserve, asset);
        
        uint256 userBalance = rayMul(userData.scaledBalance[asset], reserve.liquidityIndex);
        uint256 amountToWithdraw = amount;
        
        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }
        
        require(amountToWithdraw <= userBalance, "Not enough balance");
        require(amountToWithdraw > 0, "Amount is 0");
        
        // Validate withdrawal doesn't break health factor
        if (userData.usageAsCollateralEnabled[asset]) {
            _validateHealthFactorAfterWithdraw(asset, msg.sender, amountToWithdraw);
        }
        
        uint256 amountToWithdrawScaled = rayDiv(amountToWithdraw, reserve.liquidityIndex);
        
        userData.scaledBalance[asset] -= amountToWithdrawScaled;
        reserve.scaledTotalSupply -= amountToWithdrawScaled;
        
        if (userData.scaledBalance[asset] == 0) {
            userData.usageAsCollateralEnabled[asset] = false;
            emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
        }
        
        IERC20(asset).safeTransfer(to, amountToWithdraw);
        
        emit Withdraw(asset, msg.sender, to, amountToWithdraw);
        
        return amountToWithdraw;
    }

    /**
     * @dev Borrows an asset from the protocol
     * @param asset The address of the underlying asset to borrow
     * @param amount The amount to be borrowed
     * @param onBehalfOf Address of the user who will receive the debt
     * @param referralCode Code used to register the integrator originating the operation
     */
    function borrow(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external nonReentrant onlyActiveTrueFrozenFalse(asset) {
        require(amount > 0, "Amount must be greater than 0");
        require(reserves[asset].canBeBorrowed, "Borrowing not enabled");
        
        ReserveData storage reserve = reserves[asset];
        UserData storage userData = users[onBehalfOf];
        
        updateState(reserve, asset);
        
        uint256 amountInDebtTokens = rayDiv(amount, reserve.variableBorrowIndex);
        require(amountInDebtTokens > 0, "Amount too small");
        
        // ✅ 修复：先验证，再更新状态
        _validateBorrow(asset, onBehalfOf, amount);
        
        userData.scaledVariableDebt[asset] += amountInDebtTokens;
        reserve.scaledTotalVariableDebt += amountInDebtTokens;
        
        IERC20(asset).safeTransfer(onBehalfOf, amount);
        
        emit Borrow(asset, msg.sender, onBehalfOf, amount, referralCode);
    }

    /**
     * @dev Repays a borrowed asset
     * @param asset The address of the borrowed underlying asset previously borrowed
     * @param amount The amount to repay (use type(uint256).max to repay all)
     * @param onBehalfOf Address of the user who will get his debt reduced
     * @return The final amount repaid
     */
    function repay(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external nonReentrant onlyValidReserve(asset) returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        UserData storage userData = users[onBehalfOf];
        
        updateState(reserve, asset);
        
        uint256 variableDebt = rayMul(userData.scaledVariableDebt[asset], reserve.variableBorrowIndex);
        uint256 paybackAmount = variableDebt;
        
        if (amount < paybackAmount) {
            paybackAmount = amount;
        }
        
        require(paybackAmount > 0, "No debt to repay");
        
        uint256 paybackAmountScaled = rayDiv(paybackAmount, reserve.variableBorrowIndex);
        
        userData.scaledVariableDebt[asset] -= paybackAmountScaled;
        reserve.scaledTotalVariableDebt -= paybackAmountScaled;
        
        IERC20(asset).safeTransferFrom(msg.sender, address(this), paybackAmount);
        
        emit Repay(asset, onBehalfOf, msg.sender, paybackAmount);
        
        return paybackAmount;
    }

    /**
     * @dev Liquidates a user position when health factor drops below 1
     */
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external nonReentrant {
        require(debtToCover > 0, "Debt to cover must be greater than 0");
        
        ReserveData storage collateralReserve = reserves[collateralAsset];
        ReserveData storage debtReserve = reserves[debtAsset];
        UserData storage userData = users[user];
        
        updateState(collateralReserve, collateralAsset);
        updateState(debtReserve, debtAsset);
        
        (, , , uint256 healthFactor, , ) = getUserAccountData(user);
        require(healthFactor < MIN_HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "Health factor not below threshold");
        
        uint256 userVariableDebt = rayMul(userData.scaledVariableDebt[debtAsset], debtReserve.variableBorrowIndex);
        
        uint256 actualDebtToCover = debtToCover > userVariableDebt ? userVariableDebt : debtToCover;
        
        (uint256 maxLiquidatableDebt, uint256 liquidationBonus) = _calculateAvailableCollateralToLiquidate(
            collateralReserve,
            debtReserve,
            collateralAsset,
            debtAsset,
            actualDebtToCover,
            rayMul(userData.scaledBalance[collateralAsset], collateralReserve.liquidityIndex),
            healthFactor
        );
        
        if (maxLiquidatableDebt < actualDebtToCover) {
            actualDebtToCover = maxLiquidatableDebt;
        }
        
        // Calculate liquidation amounts
        uint256 liquidatedCollateralAmount = _calculateLiquidationAmount(
            actualDebtToCover,
            assetPrices[debtAsset],
            assetPrices[collateralAsset],
            liquidationBonus,
            debtReserve.decimals,
            collateralReserve.decimals
        );
        
        // Update user balances
        uint256 debtAmountScaled = rayDiv(actualDebtToCover, debtReserve.variableBorrowIndex);
        userData.scaledVariableDebt[debtAsset] -= debtAmountScaled;
        debtReserve.scaledTotalVariableDebt -= debtAmountScaled;
        
        uint256 collateralAmountScaled = rayDiv(liquidatedCollateralAmount, collateralReserve.liquidityIndex);
        userData.scaledBalance[collateralAsset] -= collateralAmountScaled;
        collateralReserve.scaledTotalSupply -= collateralAmountScaled;
        
        // Check for bad debt and cleanup if necessary
        _handleBadDebtCleanup(user);
        
        // Transfer debt payment from liquidator
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), actualDebtToCover);
        
        // Transfer collateral to liquidator
        if (!receiveAToken) {
            IERC20(collateralAsset).safeTransfer(msg.sender, liquidatedCollateralAmount);
        }
        
        emit LiquidationCall(
            collateralAsset,
            debtAsset,
            user,
            actualDebtToCover,
            liquidatedCollateralAmount,
            msg.sender,
            receiveAToken
        );
    }

    // ============ View Functions ============
    
    /**
     * @dev Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralBase Total collateral of the user in the base currency used by the price feed
     * @return totalDebtBase Total debt of the user in the base currency used by the price feed
     * @return availableBorrowsBase Available borrows for the user in the base currency used by the price feed
     * @return currentLiquidationThreshold Liquidation threshold of the user
     * @return ltv Loan to value of the user
     * @return healthFactor Current health factor of the user
     */
    function getUserAccountData(
        address user
    )
        public
        view 
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) 
    {
        return _getUserAccountData(user);
    }

    /**
     * @dev Gets real-time user account data with asset-level breakdown (Frontend helper)
     * @param user The user address
     * @return assets Array of asset addresses user has positions in
     * @return supplyBalances Array of real-time supply balances (including accrued interest)
     * @return borrowBalances Array of real-time borrow balances (including accrued interest)
     * @return supplyBalancesUSD Array of supply balances in USD
     * @return borrowBalancesUSD Array of borrow balances in USD
     * @return totalCollateralUSD Total collateral value in USD
     * @return totalDebtUSD Total debt value in USD
     * @return healthFactor Current health factor
     */
    function getUserAccountDataDetailed(address user) external view returns (
        address[] memory assets,
        uint256[] memory supplyBalances,
        uint256[] memory borrowBalances,
        uint256[] memory supplyBalancesUSD,
        uint256[] memory borrowBalancesUSD,
        uint256 totalCollateralUSD,
        uint256 totalDebtUSD,
        uint256 healthFactor
    ) {
        UserData storage userData = users[user];
        
        // Count user positions
        uint256 positionCount = 0;
        for (uint256 i = 0; i < reservesList.length; i++) {
            address asset = reservesList[i];
            if (!reserves[asset].isActive) continue;
            
            if (userData.scaledBalance[asset] > 0 || userData.scaledVariableDebt[asset] > 0) {
                positionCount++;
            }
        }
        
        // Initialize arrays
        assets = new address[](positionCount);
        supplyBalances = new uint256[](positionCount);
        borrowBalances = new uint256[](positionCount);
        supplyBalancesUSD = new uint256[](positionCount);
        borrowBalancesUSD = new uint256[](positionCount);
        
        // Fill position data
        uint256 index = 0;
        for (uint256 i = 0; i < reservesList.length; i++) {
            address asset = reservesList[i];
            ReserveData storage reserve = reserves[asset];
            
            if (!reserve.isActive) continue;
            
            bool hasSupply = userData.scaledBalance[asset] > 0;
            bool hasBorrow = userData.scaledVariableDebt[asset] > 0;
            
            if (hasSupply || hasBorrow) {
                assets[index] = asset;
                
                uint256 tokenUnit = 10**reserve.decimals;
                uint256 price = assetPrices[asset];
                
                // Calculate real-time supply balance (with accrued interest)
                if (hasSupply) {
                    uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(reserve, asset);
                    supplyBalances[index] = rayMul(userData.scaledBalance[asset], currentLiquidityIndex);
                    supplyBalancesUSD[index] = (price * supplyBalances[index]) / tokenUnit;
                    totalCollateralUSD += supplyBalancesUSD[index];
                }
                
                // Calculate real-time borrow balance (with accrued interest)
                if (hasBorrow) {
                    uint256 currentBorrowIndex = _getCurrentBorrowIndex(reserve, asset);
                    borrowBalances[index] = rayMul(userData.scaledVariableDebt[asset], currentBorrowIndex);
                    borrowBalancesUSD[index] = (price * borrowBalances[index]) / tokenUnit;
                    totalDebtUSD += borrowBalancesUSD[index];
                }
                
                index++;
            }
        }
        
        // Calculate health factor
        (, , , , , healthFactor) = _getUserAccountData(user);
    }

    /**
     * @dev Gets the user's current balance for a given asset (with real-time interest)
     * @param user The user address
     * @param asset The asset address
     * @return The user's current balance (including real-time interest)
     */
    function balanceOf(address user, address asset) external view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(reserve, asset);
        return rayMul(users[user].scaledBalance[asset], currentLiquidityIndex);
    }

    /**
     * @dev Gets the user's current debt for a given asset (with real-time interest)
     * @param user The user address
     * @param asset The asset address
     * @return The user's current variable debt (including real-time interest)
     */
    function getUserVariableDebt(address user, address asset) external view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        uint256 currentBorrowIndex = _getCurrentBorrowIndex(reserve, asset);
        return rayMul(users[user].scaledVariableDebt[asset], currentBorrowIndex);
    }

    /**
     * @dev Returns the list of all initialized reserves
     * @return The list of addresses of all initialized reserves
     */
    function getReservesList() external view returns (address[] memory) {
        return reservesList;
    }

    /**
     * @dev Manually updates the interest for a specific asset
     * @param asset The asset to update interest for
     */
    function updateInterest(address asset) external onlyValidReserve(asset) {
        ReserveData storage reserve = reserves[asset];
        updateState(reserve, asset);
    }

    /**
     * @dev Updates interest for all active reserves
     */
    function updateAllInterests() external {
        for (uint256 i = 0; i < reservesList.length; i++) {
            address asset = reservesList[i];
            if (reserves[asset].isActive) {
                updateState(reserves[asset], asset);
            }
        }
    }





    // ============ Internal Functions ============
    
    /**
     * @dev Calculates the current liquidity index without updating state
     * @param reserve The reserve data
     * @param asset The asset address (needed for real-time rate calculation)
     * @return The current liquidity index including accrued interest
     */
    function _getCurrentLiquidityIndex(ReserveData storage reserve, address asset) internal view returns (uint256) {
        uint256 scaledVariableDebt = reserve.scaledTotalVariableDebt;
        if (scaledVariableDebt == 0) {
            return reserve.liquidityIndex;
        }
        
        // Use real-time dynamic rate instead of stored rate
        uint256 currentDynamicRate = calculateCurrentVariableBorrowRate(asset);
        
        uint256 cumulatedVariableBorrowInterest = calculateCompoundedInterest(
            currentDynamicRate,
            reserve.lastUpdateTimestamp
        );
        uint256 currentVariableBorrowIndex = rayMul(reserve.variableBorrowIndex, cumulatedVariableBorrowInterest);
        
        uint256 totalDebt = rayMul(scaledVariableDebt, currentVariableBorrowIndex);
        uint256 previousTotalDebt = rayMul(scaledVariableDebt, reserve.variableBorrowIndex);
        uint256 debtIncrease = totalDebt - previousTotalDebt;
        
        uint256 protocolFee = rayMul(debtIncrease, wadToRay(protocolFeeRate * 1e14));
        
        if (reserve.scaledTotalSupply == 0) {
            return reserve.liquidityIndex;
        }
        
        uint256 liquidityIncrease = debtIncrease - protocolFee;
        uint256 cumulatedLiquidityInterest = rayDiv(liquidityIncrease, reserve.scaledTotalSupply) + RAY;
        return rayMul(reserve.liquidityIndex, cumulatedLiquidityInterest);
    }
    
    /**
     * @dev Calculates the current borrow index without updating state
     * @param reserve The reserve data
     * @param asset The asset address (needed for real-time rate calculation)
     * @return The current variable borrow index including accrued interest
     */
    function _getCurrentBorrowIndex(ReserveData storage reserve, address asset) internal view returns (uint256) {
        uint256 scaledVariableDebt = reserve.scaledTotalVariableDebt;
        if (scaledVariableDebt == 0) {
            return reserve.variableBorrowIndex;
        }
        
        // Use real-time dynamic rate instead of stored rate
        uint256 currentDynamicRate = calculateCurrentVariableBorrowRate(asset);
        
        uint256 cumulatedVariableBorrowInterest = calculateCompoundedInterest(
            currentDynamicRate,
            reserve.lastUpdateTimestamp
        );
        return rayMul(reserve.variableBorrowIndex, cumulatedVariableBorrowInterest);
    }

    /**
     * @dev Calculates the current variable borrow rate based on utilization
     * @param asset The asset address
     * @return The current variable borrow rate (in Ray)
     */
    function calculateCurrentVariableBorrowRate(address asset) public view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        InterestRateModel storage model = interestRateModels[asset];
        
        // Get current liquidity and debt
        uint256 totalLiquidity = rayMul(reserve.scaledTotalSupply, reserve.liquidityIndex);
        uint256 totalDebt = rayMul(reserve.scaledTotalVariableDebt, reserve.variableBorrowIndex);
        
        // If no debt or liquidity, return base rate
        if (totalDebt == 0 || totalLiquidity == 0) {
            return model.baseRatePerYear;
        }
        
        // Calculate utilization rate using AAVE formula
        uint256 utilizationRate = rayDiv(totalDebt, totalLiquidity);
        
        // Cap utilization rate at 100% for rate calculation
        if (utilizationRate > RAY) {
            utilizationRate = RAY; // 100%
        }
        
        // Calculate interest rate based on utilization
        if (utilizationRate <= model.kink) {
            // Below kink: rate = baseRate + (utilizationRate * multiplier)
            return model.baseRatePerYear + rayMul(utilizationRate, model.multiplierPerYear);
        } else {
            // Above kink: rate = baseRate + (kink * multiplier) + ((utilizationRate - kink) * jumpMultiplier)
            uint256 normalRate = model.baseRatePerYear + rayMul(model.kink, model.multiplierPerYear);
            uint256 excessUtil = utilizationRate - model.kink;
            return normalRate + rayMul(excessUtil, model.jumpMultiplierPerYear);
        }
    }
    
    /**
     * @dev Gets the current utilization rate for an asset
     * @param asset The asset address
     * @return utilizationRate The utilization rate (in Ray)
     */
    function getUtilizationRate(address asset) public view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        
        uint256 totalLiquidity = rayMul(reserve.scaledTotalSupply, reserve.liquidityIndex);
        uint256 totalDebt = rayMul(reserve.scaledTotalVariableDebt, reserve.variableBorrowIndex);
        
        if (totalDebt == 0 || totalLiquidity == 0) {
            return 0;
        }
        
        // ✅ AAVE正确公式：利用率 = 总借款 / 总存款
        uint256 utilizationRate = rayDiv(totalDebt, totalLiquidity);
        
        // Cap at 100% for consistency  
        if (utilizationRate > RAY) {
            utilizationRate = RAY; // 100%
        }
        
        return utilizationRate;
    }

    /**
     * @dev Calculates the current liquidity (supply) rate
     * @param asset The asset address
     * @return The current liquidity rate (in Ray) - what suppliers earn
     */
    function calculateCurrentLiquidityRate(address asset) public view returns (uint256) {
        uint256 borrowRate = calculateCurrentVariableBorrowRate(asset);
        uint256 utilizationRate = getUtilizationRate(asset);
        
        if (utilizationRate == 0) {
            return 0;
        }
        
        // Supply rate = Borrow rate × Utilization rate × (1 - Protocol fee rate)
        uint256 grossSupplyRate = rayMul(borrowRate, utilizationRate);
        uint256 protocolFeeDecimal = wadToRay(protocolFeeRate * 1e14); // Convert basis points to ray
        uint256 netSupplyRate = rayMul(grossSupplyRate, RAY - protocolFeeDecimal);
        
        return netSupplyRate;
    }

    /**
     * @dev Gets comprehensive rate information for an asset (Frontend helper)
     * @param asset The asset address
     * @return supplyRate The current supply/deposit rate (Ray format, annual)
     * @return borrowRate The current variable borrow rate (Ray format, annual)  
     * @return utilizationRate The current utilization rate (Ray format)
     * @return supplyRatePercent Supply rate in percentage (2 decimals: 250 = 2.50%)
     * @return borrowRatePercent Borrow rate in percentage (2 decimals: 1050 = 10.50%)
     * @return utilizationPercent Utilization in percentage (2 decimals: 8250 = 82.50%)
     */
    function getAssetRates(address asset) external view returns (
        uint256 supplyRate,
        uint256 borrowRate, 
        uint256 utilizationRate,
        uint256 supplyRatePercent,
        uint256 borrowRatePercent,
        uint256 utilizationPercent
    ) {
        require(reserves[asset].isActive, "Reserve not active");
        
        supplyRate = calculateCurrentLiquidityRate(asset);
        borrowRate = calculateCurrentVariableBorrowRate(asset);
        utilizationRate = getUtilizationRate(asset);
        
        // Convert to percentage with 2 decimal places (divide by 1e25, multiply by 10000)
        // Ray (1e27) to percentage with 2 decimals: rate * 10000 / 1e25 = rate / 1e23
        supplyRatePercent = supplyRate / 1e23;
        borrowRatePercent = borrowRate / 1e23; 
        utilizationPercent = utilizationRate / 1e23;
    }

    /**
     * @dev Gets rates for all active assets (Batch query for frontend)
     * @return assets Array of asset addresses
     * @return supplyRates Array of supply rates (percentage with 2 decimals)
     * @return borrowRates Array of borrow rates (percentage with 2 decimals)
     * @return utilizationRates Array of utilization rates (percentage with 2 decimals)
     */
    function getAllAssetRates() external view returns (
        address[] memory assets,
        uint256[] memory supplyRates,
        uint256[] memory borrowRates,
        uint256[] memory utilizationRates
    ) {
        uint256 activeCount = 0;
        
        // Count active reserves
        for (uint256 i = 0; i < reservesList.length; i++) {
            if (reserves[reservesList[i]].isActive) {
                activeCount++;
            }
        }
        
        // Initialize arrays
        assets = new address[](activeCount);
        supplyRates = new uint256[](activeCount);
        borrowRates = new uint256[](activeCount);
        utilizationRates = new uint256[](activeCount);
        
        // Fill arrays
        uint256 index = 0;
        for (uint256 i = 0; i < reservesList.length; i++) {
            address asset = reservesList[i];
            if (reserves[asset].isActive) {
                assets[index] = asset;
                
                uint256 supplyRate = calculateCurrentLiquidityRate(asset);
                uint256 borrowRate = calculateCurrentVariableBorrowRate(asset);
                uint256 utilizationRate = getUtilizationRate(asset);
                
                // Convert to percentage with 2 decimal places
                supplyRates[index] = supplyRate / 1e23;
                borrowRates[index] = borrowRate / 1e23;
                utilizationRates[index] = utilizationRate / 1e23;
                
                index++;
            }
        }
    }

    function _getUserAccountData(
        address user
    )
        internal 
        view 
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) 
    {
        UserData storage userData = users[user];
        
        if (reservesList.length == 0) {
            return (0, 0, 0, 0, 0, type(uint256).max);
        }

        uint256 avgLtv;
        uint256 avgLiquidationThreshold;
        uint256 totalCollateralForLTV; // ✅ 新增：只计算启用作为抵押品的资产总价值
        
        for (uint256 i = 0; i < reservesList.length; i++) {
            address currentReserveAddress = reservesList[i];
            ReserveData storage currentReserve = reserves[currentReserveAddress];
            
            if (!currentReserve.isActive) continue;
            
            (uint256 ltv, uint256 liquidationThreshold, , , ) = getConfiguration(currentReserveAddress);
            
            uint256 tokenUnit = 10**currentReserve.decimals;
            uint256 price = assetPrices[currentReserveAddress];
            
            if (userData.scaledBalance[currentReserveAddress] != 0) {
                uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(currentReserve, currentReserveAddress);
                uint256 balance = rayMul(userData.scaledBalance[currentReserveAddress], currentLiquidityIndex);
                uint256 balanceInBaseCurrency = (price * balance) / tokenUnit;
                totalCollateralBase += balanceInBaseCurrency;
                
                if (userData.usageAsCollateralEnabled[currentReserveAddress]) {
                    totalCollateralForLTV += balanceInBaseCurrency; // ✅ 只累计启用作为抵押品的资产
                    avgLtv += balanceInBaseCurrency * ltv;
                    avgLiquidationThreshold += balanceInBaseCurrency * liquidationThreshold;
                }
            }
            
            if (userData.scaledVariableDebt[currentReserveAddress] != 0) {
                uint256 currentBorrowIndex = _getCurrentBorrowIndex(currentReserve, currentReserveAddress);
                uint256 debt = rayMul(userData.scaledVariableDebt[currentReserveAddress], currentBorrowIndex);
                uint256 debtInBaseCurrency = (price * debt) / tokenUnit;
                totalDebtBase += debtInBaseCurrency;
            }
        }
        
        // ✅ 修复：用正确的分母计算加权平均
        if (totalCollateralForLTV > 0) {
            avgLtv = avgLtv / totalCollateralForLTV;
            avgLiquidationThreshold = avgLiquidationThreshold / totalCollateralForLTV;
        }
        
        // ✅ 修复：基于启用作为抵押品的资产计算借贷能力
        availableBorrowsBase = totalCollateralForLTV * avgLtv / BASIS_POINTS_FACTOR;
        
        if (availableBorrowsBase > totalDebtBase) {
            availableBorrowsBase = availableBorrowsBase - totalDebtBase;
        } else {
            availableBorrowsBase = 0;
        }
        
        // ✅ 修复：健康因子应该基于启用作为抵押品的资产，并使用正确的精度
        healthFactor = totalDebtBase == 0
            ? type(uint256).max
            : (totalCollateralForLTV * avgLiquidationThreshold * 1e18) / (totalDebtBase * BASIS_POINTS_FACTOR);
            
        ltv = avgLtv;
        currentLiquidationThreshold = avgLiquidationThreshold;
    }

    function _calculateCollateralForLTV(address user) internal view returns (uint256) {
        UserData storage userData = users[user];
        uint256 totalCollateralForLTV = 0;
        
        for (uint256 i = 0; i < reservesList.length; i++) {
            address currentReserveAddress = reservesList[i];
            ReserveData storage currentReserve = reserves[currentReserveAddress];
            
            if (!currentReserve.isActive) continue;
            
            if (userData.scaledBalance[currentReserveAddress] != 0 && userData.usageAsCollateralEnabled[currentReserveAddress]) {
                uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(currentReserve, currentReserveAddress);
                uint256 balance = rayMul(userData.scaledBalance[currentReserveAddress], currentLiquidityIndex);
                uint256 balanceInBaseCurrency = (assetPrices[currentReserveAddress] * balance) / (10**currentReserve.decimals);
                totalCollateralForLTV += balanceInBaseCurrency;
            }
        }
        
        return totalCollateralForLTV;
    }





    function _validateBorrow(
        address asset,
        address user,
        uint256 amount
    ) internal view {
        (, uint256 totalDebtBase, uint256 availableBorrowsBase, , , uint256 healthFactor) = _getUserAccountData(user);
        
        // Check if borrowing capacity exists (collateral enabled)
        require(availableBorrowsBase > 0, "No borrowing capacity - ensure collateral assets are enabled");
        
        uint256 amountInBaseCurrency = (assetPrices[asset] * amount) / (10**reserves[asset].decimals);
        require(amountInBaseCurrency <= availableBorrowsBase, "Amount exceeds borrowing capacity");
        
        // 健康因子检查
        if (totalDebtBase > 0) {
            require(healthFactor > MIN_HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "Current health factor too low");
        }
    }

    function _validateHealthFactorAfterWithdraw(
        address asset,
        address user,
        uint256 amountToWithdraw
    ) internal view {
        (, , , , , uint256 healthFactorBeforeWithdraw) = _getUserAccountData(user);
        
        if (healthFactorBeforeWithdraw <= MIN_HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
            revert("Health factor already too low");
        }
        
        // Simulate withdrawal and check health factor
        // This is a simplified version - in production, you'd want more detailed simulation
        UserData storage userData = users[user];
        ReserveData storage reserve = reserves[asset];
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(reserve, asset);
        uint256 currentBalance = rayMul(userData.scaledBalance[asset], currentLiquidityIndex);
        
        if (amountToWithdraw == currentBalance) {
            // Full withdrawal - need to check if health factor remains above threshold
            // Implementation details would go here
        }
    }

    function _calculateAvailableCollateralToLiquidate(
        ReserveData storage collateralReserve,
        ReserveData storage principalReserve,
        address collateralAsset,
        address principalAsset,
        uint256 debtToCover,
        uint256 userCollateralBalance,
        uint256 healthFactor
    ) internal view returns (uint256, uint256) {
        uint256 liquidationBonus = collateralReserve.liquidationBonus;
        
        uint256 maxAmountCollateralToLiquidate = ((debtToCover * assetPrices[principalAsset] * (BASIS_POINTS_FACTOR + liquidationBonus)) /
            assetPrices[collateralAsset]) /
            BASIS_POINTS_FACTOR;
            
        if (maxAmountCollateralToLiquidate > userCollateralBalance) {
            return (
                (userCollateralBalance * assetPrices[collateralAsset] * BASIS_POINTS_FACTOR) /
                (assetPrices[principalAsset] * (BASIS_POINTS_FACTOR + liquidationBonus)),
                liquidationBonus
            );
        } else {
            return (debtToCover, liquidationBonus);
        }
    }

    function _calculateLiquidationAmount(
        uint256 debtToCover,
        uint256 debtAssetPrice,
        uint256 collateralAssetPrice,
        uint256 liquidationBonus,
        uint256 debtAssetDecimals,
        uint256 collateralAssetDecimals
    ) internal pure returns (uint256) {
        uint256 collateralValue = (debtToCover * debtAssetPrice * (BASIS_POINTS_FACTOR + liquidationBonus)) / BASIS_POINTS_FACTOR;
        
        uint256 collateralAmount = (collateralValue * (10**collateralAssetDecimals)) / 
                                  (collateralAssetPrice * (10**debtAssetDecimals));
        
        return collateralAmount;
    }

    function _handleBadDebtCleanup(address user) internal {
        // Check if user has zero collateral but non-zero debt
        UserData storage userData = users[user];
        bool hasCollateral = false;
        bool hasDebt = false;
        
        for (uint256 i = 0; i < reservesList.length; i++) {
            address asset = reservesList[i];
            ReserveData storage reserve = reserves[asset];
            
            if (userData.scaledBalance[asset] > 0) {
                uint256 balance = rayMul(userData.scaledBalance[asset], reserve.liquidityIndex);
                if (balance > 0) {
                    hasCollateral = true;
                }
            }
            
            if (userData.scaledVariableDebt[asset] > 0) {
                uint256 debt = rayMul(userData.scaledVariableDebt[asset], reserve.variableBorrowIndex);
                if (debt > 0) {
                    hasDebt = true;
                }
            }
        }
        
        // If user has debt but no collateral, burn the debt and record as deficit
        if (hasDebt && !hasCollateral) {
            for (uint256 i = 0; i < reservesList.length; i++) {
                address asset = reservesList[i];
                ReserveData storage reserve = reserves[asset];
                
                if (userData.scaledVariableDebt[asset] > 0) {
                    uint256 debtAmount = rayMul(userData.scaledVariableDebt[asset], reserve.variableBorrowIndex);
                    
                    // Record as deficit
                    reserve.deficit += debtAmount;
                    
                    // Burn the debt
                    reserve.scaledTotalVariableDebt -= userData.scaledVariableDebt[asset];
                    userData.scaledVariableDebt[asset] = 0;
                }
            }
        }
    }

    function getConfiguration(address asset) public view returns (
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 decimals,
        bool usageAsCollateralEnabled
    ) {
        ReserveData storage reserve = reserves[asset];
        return (
            reserve.ltv,
            reserve.liquidationThreshold,
            reserve.liquidationBonus,
            reserve.decimals,
            reserve.canBeCollateral
        );
    }

    // ============ Admin Functions ============
    
    /**
     * @dev Updates asset price
     */
    function updatePrice(address asset, uint256 price) external onlyOwner {
        require(price > 0, "Invalid price");
        assetPrices[asset] = price;
        emit PriceUpdated(asset, price);
    }

    /**
     * @dev Updates multiple asset prices
     */
    function updatePrices(address[] calldata assets, uint256[] calldata prices) external onlyOwner {
        require(assets.length == prices.length, "Arrays length mismatch");
        
        for (uint256 i = 0; i < assets.length; i++) {
            require(prices[i] > 0, "Invalid price");
            assetPrices[assets[i]] = prices[i];
            emit PriceUpdated(assets[i], prices[i]);
        }
    }
    
    /**
     * @dev Sets the configuration of the reserve (risk parameters only)
     * @dev Use setInterestRateModel() to change interest rates
     */
    function setReserveConfiguration(
        address asset,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) external onlyOwner {
        require(ltv <= liquidationThreshold, "LTV must be <= liquidation threshold");
        require(liquidationThreshold <= BASIS_POINTS_FACTOR, "Invalid liquidation threshold");
        require(liquidationBonus <= BASIS_POINTS_FACTOR, "Invalid liquidation bonus");
        require(reserves[asset].isActive, "Reserve not active");
        
        ReserveData storage reserve = reserves[asset];
        
        // Update state before changing configuration
        updateState(reserve, asset);
        
        reserve.ltv = ltv;
        reserve.liquidationThreshold = liquidationThreshold;
        reserve.liquidationBonus = liquidationBonus;
        
        emit ReserveDataUpdated(
            asset,
            0, // No longer using fixed liquidity rate
            reserve.currentVariableBorrowRate, // Keep current dynamic rate
            reserve.liquidityIndex,
            reserve.variableBorrowIndex
        );
    }

    /**
     * @dev Withdraws accumulated protocol fees for a specific asset
     * @param asset The asset to withdraw fees from
     * @param to The address to send the fees to
     */
    function withdrawTreasuryFees(address asset, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient address");
        require(reserves[asset].isActive, "Reserve not active");
        
        ReserveData storage reserve = reserves[asset];
        
        // Update state to ensure latest fees are accrued
        updateState(reserve, asset);
        
        uint256 accruedAmount = reserve.accruedToTreasury;
        require(accruedAmount > 0, "No fees to withdraw");
        
        // Convert scaled amount to actual amount
        uint256 actualAmount = rayMul(accruedAmount, reserve.liquidityIndex);
        
        // Reset accrued treasury balance
        reserve.accruedToTreasury = 0;
        
        // Transfer the fees
        IERC20(asset).safeTransfer(to, actualAmount);
        
        emit TreasuryWithdraw(asset, actualAmount, to);
    }

    /**
     * @dev Withdraws all accumulated protocol fees across all assets
     * @param to The address to send the fees to
     */
    function withdrawAllTreasuryFees(address to) external onlyOwner {
        require(to != address(0), "Invalid recipient address");
        
        for (uint256 i = 0; i < reservesList.length; i++) {
            address asset = reservesList[i];
            ReserveData storage reserve = reserves[asset];
            
            if (!reserve.isActive || reserve.accruedToTreasury == 0) continue;
            
            // Update state to ensure latest fees are accrued
            updateState(reserve, asset);
            
            uint256 accruedAmount = reserve.accruedToTreasury;
            if (accruedAmount == 0) continue;
            
            // Convert scaled amount to actual amount
            uint256 actualAmount = rayMul(accruedAmount, reserve.liquidityIndex);
            
            // Reset accrued treasury balance
            reserve.accruedToTreasury = 0;
            
            // Transfer the fees
            IERC20(asset).safeTransfer(to, actualAmount);
            
            emit TreasuryWithdraw(asset, actualAmount, to);
        }
    }

    /**
     * @dev Gets the accumulated treasury fees for a specific asset
     * @param asset The asset to check
     * @return scaledAmount The scaled amount of fees
     * @return actualAmount The actual amount of fees (in asset units)
     */
    function getTreasuryFees(address asset) external view returns (uint256 scaledAmount, uint256 actualAmount) {
        ReserveData storage reserve = reserves[asset];
        scaledAmount = reserve.accruedToTreasury;
        actualAmount = rayMul(scaledAmount, reserve.liquidityIndex);
    }

    /**
     * @dev Gets total treasury fees across all assets (in USD value)
     * @return totalFeesUSD Total fees value in USD (18 decimal precision)
     */
    function getTotalTreasuryFeesUSD() external view returns (uint256 totalFeesUSD) {
        for (uint256 i = 0; i < reservesList.length; i++) {
            address asset = reservesList[i];
            ReserveData storage reserve = reserves[asset];
            
            if (!reserve.isActive || reserve.accruedToTreasury == 0) continue;
            
            uint256 actualAmount = rayMul(reserve.accruedToTreasury, reserve.liquidityIndex);
            uint256 tokenUnit = 10**reserve.decimals;
            uint256 price = assetPrices[asset];
            
            totalFeesUSD += (price * actualAmount) / tokenUnit;
        }
    }

    /**
     * @dev Sets the protocol fee rate
     * @param newRate The new fee rate in basis points (e.g., 1000 = 10%)
     */
    function setProtocolFeeRate(uint256 newRate) external onlyOwner {
        require(newRate <= 5000, "Fee rate too high (max 50%)"); // Max 50%
        
        uint256 oldRate = protocolFeeRate;
        protocolFeeRate = newRate;
        
        emit ProtocolFeeRateUpdated(oldRate, newRate);
    }

    /**
     * @dev Sets the interest rate model for an asset
     * @param asset The asset address
     * @param baseRatePerYear Base interest rate (Ray format)
     * @param multiplierPerYear Slope 1 rate (Ray format) 
     * @param jumpMultiplierPerYear Slope 2 rate (Ray format)
     * @param kink Optimal utilization rate (Ray format)
     */
    function setInterestRateModel(
        address asset,
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink
    ) external onlyOwner {
        require(reserves[asset].isActive, "Reserve not active");
        require(kink <= RAY, "Invalid kink value");
        require(baseRatePerYear <= RAY, "Invalid base rate");
        
        // Update state before changing rate model
        ReserveData storage reserve = reserves[asset];
        updateState(reserve, asset);
        
        interestRateModels[asset] = InterestRateModel({
            baseRatePerYear: baseRatePerYear,
            multiplierPerYear: multiplierPerYear,
            jumpMultiplierPerYear: jumpMultiplierPerYear,
            kink: kink
        });
        
        // Update current rate immediately
        uint256 newRate = calculateCurrentVariableBorrowRate(asset);
        reserve.currentVariableBorrowRate = newRate;
        
        emit ReserveDataUpdated(
            asset,
            0,
            newRate,
            reserve.liquidityIndex,
            reserve.variableBorrowIndex
        );
    }

    /**
     * @dev Gets the interest rate model for an asset
     * @param asset The asset address
     * @return baseRatePerYear Base interest rate
     * @return multiplierPerYear Slope 1 rate
     * @return jumpMultiplierPerYear Slope 2 rate  
     * @return kink Optimal utilization rate
     */
    function getInterestRateModel(address asset) external view returns (
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink
    ) {
        InterestRateModel storage model = interestRateModels[asset];
        return (
            model.baseRatePerYear,
            model.multiplierPerYear,
            model.jumpMultiplierPerYear,
            model.kink
        );
    }

    // ============ Emergency Functions ============
    
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

}
