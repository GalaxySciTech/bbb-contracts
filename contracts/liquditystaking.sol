// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "./interfaces/IXDCValidator.sol";
import "./interfaces/IKYCVerifier.sol";
import "./WXDC.sol";
import "./RewardsVault.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title bXDC
 * @dev ERC4626 tokenized vault - liquid staking receipt token for XDC
 * Asset: WXDC (wrapped XDC). Shares: bXDC. Value grows with staking rewards.
 */
contract bXDC is ERC4626, AccessControl {
    bytes32 public constant STAKING_POOL_ROLE = keccak256("STAKING_POOL_ROLE");
    address public stakingPool;

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only staking pool can call");
        _;
    }

    constructor(IERC20 asset_, address admin_) ERC4626(asset_) ERC20("Staked XDC", "bXDC") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function setStakingPool(address _stakingPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingPool != address(0), "Invalid address");
        address old = stakingPool;
        stakingPool = _stakingPool;
        if (old != address(0)) _revokeRole(STAKING_POOL_ROLE, old);
        _grantRole(STAKING_POOL_ROLE, _stakingPool);
        emit StakingPoolSet(_stakingPool);
    }

    event StakingPoolSet(address indexed stakingPool);

    /// @dev Staking pool overrides totalAssets - use internal for conversions
    function totalAssets() public view virtual override returns (uint256) {
        if (stakingPool == address(0)) return IERC20(asset()).balanceOf(address(this));
        return IXDCVault(stakingPool).totalPooledXDC();
    }

    /// @dev Allow staking pool to mint (for native XDC stake flow)
    function mint(address to, uint256 amount) external onlyStakingPool {
        _mint(to, amount);
    }

    /// @dev Allow staking pool to burn (for withdrawal flows)
    function burn(address from, uint256 amount) external onlyStakingPool {
        _burn(from, amount);
    }

    /// @dev Use staking pool for deposits
    function deposit(uint256, address) public pure override returns (uint256) {
        revert("Use XDCLiquidityStaking.deposit or stake");
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert("Use XDCLiquidityStaking.mint or stake");
    }
}

interface IXDCVault {
    function totalPooledXDC() external view returns (uint256);
}

/**
 * @title WithdrawalRequestNFT
 * @dev ERC-1155 NFT representing a withdrawal claim during unbonding period
 */
contract WithdrawalRequestNFT is ERC1155Supply, AccessControl {
    bytes32 public constant STAKING_POOL_ROLE = keccak256("STAKING_POOL_ROLE");
    address public stakingPool;

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only staking pool");
        _;
    }

    constructor(address admin_) ERC1155("") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return ERC1155.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
    }

    function setStakingPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pool != address(0), "Invalid address");
        address old = stakingPool;
        stakingPool = _pool;
        if (old != address(0)) _revokeRole(STAKING_POOL_ROLE, old);
        _grantRole(STAKING_POOL_ROLE, _pool);
        emit StakingPoolSet(_pool);
    }

    event StakingPoolSet(address indexed stakingPool);

    function mint(address to, uint256 id, uint256 amount) external onlyStakingPool {
        _mint(to, id, amount, "");
    }

    function burn(address from, uint256 id, uint256 amount) external onlyStakingPool {
        _burn(from, id, amount);
    }

    function uri(uint256) public pure override returns (string memory) {
        return "ipfs://withdrawal-request";
    }
}

/**
 * @title XDCLiquidityStaking
 * @dev XDC Liquid Staking Protocol - role-based, auto-deploy masternodes, RewardsVault
 * LSP = admin (params, pause). Operators = KYC-verified addresses (coinbase). Rewards only from 0x88.
 */
contract XDCLiquidityStaking is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant LSP_ADMIN_ROLE = keccak256("LSP_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    bXDC public bxdcToken;
    WXDC public wxdc;
    WithdrawalRequestNFT public withdrawalNFT;
    RewardsVault public rewardsVault;

    IXDCValidator public validator;
    IKYCVerifier public kycVerifier;

    uint256 public constant DEFAULT_MASTERNODE_CAP = 10_000_000 ether;
    uint256 public masternodeStakeAmount = 10_000_000 ether;
    uint256 public withdrawDelayBlocks = 1_296_000;

    uint256 public totalPooledXDC;
    uint256 public totalStakedInMasternodes;
    uint256 public totalInUnbonding;

    uint256 public nextWithdrawalBatchId;
    uint256 public instantExitBuffer;

    mapping(uint256 => WithdrawalBatch) public withdrawalBatches;
    mapping(address => uint256[]) public userWithdrawalBatches;

    struct WithdrawalBatch {
        uint256 xdcAmount;
        uint256 unlockBlock;
        bool redeemed;
    }

    mapping(address => bool) public operators;
    address[] public operatorList;
    mapping(address => address[]) public masternodeOperators;

    uint256 public minStakeAmount = 1 ether;
    uint256 public minWithdrawAmount = 0.1 ether;
    uint256 public maxWithdrawablePercentage = 80;

    bool public lspKYCSubmitted;

    address public lendingProtocol;
    uint256 public bufferLendingLimit = 0;

    uint256 public timelockDelay = 1 days;
    uint256 public emergencyTimelockDelay = 1 hours;

    mapping(bytes32 => PendingChange) public pendingChanges;
    uint256 public pendingPauseAt;
    uint256 public pendingUnpauseAt;

    struct PendingChange {
        uint256 value;
        uint256 executableAt;
        bool isAddress;
        address addressValue;
    }

    uint256 public pendingResignAmount;

    event Staked(address indexed user, uint256 xdcAmount, uint256 bxdcAmount, uint256 exchangeRate);
    event WithdrawalRequested(uint256 indexed batchId, address indexed user, uint256 bxdcAmount, uint256 xdcAmount);
    event WithdrawalRedeemed(uint256 indexed batchId, address indexed user, uint256 xdcAmount);
    event WithdrawalNFTMinted(uint256 indexed batchId, address indexed user, uint256 xdcAmount);
    event MasternodeProposed(address indexed operator, uint256 amount);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event RewardsHarvested(uint256 amount, uint256 newExchangeRate);
    event LSPKYCSubmitted(string kycHash);
    event InstantExit(address indexed user, uint256 xdcAmount);
    event ParameterProposed(bytes32 indexed param, uint256 value, uint256 executableAt);
    event ParameterChanged(bytes32 indexed param, uint256 value);
    event AddressParameterProposed(bytes32 indexed param, address value, uint256 executableAt);
    event AddressParameterChanged(bytes32 indexed param, address value);
    event MasternodeResigned(address indexed operator, uint256 amount);
    event InstantExitBufferToppedUp(uint256 amount);

    constructor(address _validator, address _wxdc, address _lspAdmin) {
        require(_validator != address(0), "Invalid validator");
        require(_wxdc != address(0), "Invalid WXDC");
        require(_lspAdmin != address(0), "Invalid LSP admin");
        validator = IXDCValidator(_validator);
        wxdc = WXDC(payable(_wxdc));
        _grantRole(DEFAULT_ADMIN_ROLE, _lspAdmin);
        _grantRole(LSP_ADMIN_ROLE, _lspAdmin);
        _setRoleAdmin(OPERATOR_ROLE, LSP_ADMIN_ROLE);

        bxdcToken = new bXDC(IERC20(_wxdc), address(this));
        bxdcToken.setStakingPool(address(this));
        withdrawalNFT = new WithdrawalRequestNFT(address(this));
        withdrawalNFT.setStakingPool(address(this));
        rewardsVault = new RewardsVault(address(this));
    }

    function getRewardsVaultAddress() external view returns (address) {
        return address(rewardsVault);
    }

    function setKYCVerifier(address _verifier) external onlyRole(LSP_ADMIN_ROLE) {
        kycVerifier = IKYCVerifier(_verifier);
        emit AddressParameterChanged(keccak256("KYC_VERIFIER"), _verifier);
    }

    function setLendingProtocol(address _lending, uint256 _limit) external onlyRole(LSP_ADMIN_ROLE) {
        lendingProtocol = _lending;
        bufferLendingLimit = _limit;
        emit AddressParameterChanged(keccak256("LENDING_PROTOCOL"), _lending);
        emit ParameterChanged(keccak256("BUFFER_LENDING_LIMIT"), _limit);
    }

    function getExchangeRate() public view returns (uint256) {
        uint256 supply = bxdcToken.totalSupply();
        if (supply == 0) return 1e18;
        return (totalPooledXDC * 1e18) / supply;
    }

    function getbXDCByXDC(uint256 xdcAmount) public view returns (uint256) {
        return bxdcToken.convertToShares(xdcAmount);
    }

    function getXDCBybXDC(uint256 bxdcAmount) public view returns (uint256) {
        return bxdcToken.convertToAssets(bxdcAmount);
    }

    function getAvailableBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function _verifyOperatorKYC(address operator) internal view {
        if (address(kycVerifier) != address(0)) {
            require(kycVerifier.getHashCount(operator) >= 1, "Operator not KYC'd");
        }
    }

    /// @dev Add operator - must have KYC verified first (operator submits KYC doc before eligibility)
    function addOperator(address operator) external onlyRole(LSP_ADMIN_ROLE) {
        _verifyOperatorKYC(operator);
        require(!operators[operator], "Already operator");
        operators[operator] = true;
        operatorList.push(operator);
        grantRole(OPERATOR_ROLE, operator);
        emit OperatorAdded(operator);
    }

    function removeOperator(address operator) external onlyRole(LSP_ADMIN_ROLE) {
        require(operators[operator], "Not operator");
        operators[operator] = false;
        revokeRole(OPERATOR_ROLE, operator);
        emit OperatorRemoved(operator);
    }

    function submitKYC(string calldata kycHash) external onlyRole(LSP_ADMIN_ROLE) {
        validator.uploadKYC(kycHash);
        lspKYCSubmitted = true;
        emit LSPKYCSubmitted(kycHash);
    }

    /// @dev Harvest rewards from RewardsVault - only XDC from 0x88 can inflate (validator rewards)
    function harvestRewards() external nonReentrant {
        uint256 amount = rewardsVault.collectRewards();
        if (amount > 0) {
            totalPooledXDC += amount;
            emit RewardsHarvested(amount, getExchangeRate());
        }
    }

    /// @dev Permissionless - anyone can call, but only validator sends to RewardsVault in practice.
    /// Kept for backward compat if rewards sent to staking contract directly; use harvestRewards for RewardsVault.
    function depositRewards() external payable {
        require(msg.value > 0, "Reward amount must be > 0");
        totalPooledXDC += msg.value;
        emit RewardsHarvested(msg.value, getExchangeRate());
    }

    function addToInstantExitBuffer() external payable onlyRole(LSP_ADMIN_ROLE) {
        require(msg.value > 0, "Amount must be > 0");
        instantExitBuffer += msg.value;
        emit InstantExitBufferToppedUp(msg.value);
    }

    function proposeMinStakeAmount(uint256 amount) external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("MIN_STAKE_AMOUNT");
        pendingChanges[key] = PendingChange({
            value: amount,
            executableAt: block.timestamp + timelockDelay,
            isAddress: false,
            addressValue: address(0)
        });
        emit ParameterProposed(key, amount, block.timestamp + timelockDelay);
    }

    function executeMinStakeAmount() external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("MIN_STAKE_AMOUNT");
        PendingChange storage pc = pendingChanges[key];
        require(pc.executableAt > 0 && block.timestamp >= pc.executableAt, "Timelock not passed");
        minStakeAmount = pc.value;
        delete pendingChanges[key];
        emit ParameterChanged(key, pc.value);
    }

    function proposeMinWithdrawAmount(uint256 amount) external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("MIN_WITHDRAW_AMOUNT");
        pendingChanges[key] = PendingChange({
            value: amount,
            executableAt: block.timestamp + timelockDelay,
            isAddress: false,
            addressValue: address(0)
        });
        emit ParameterProposed(key, amount, block.timestamp + timelockDelay);
    }

    function executeMinWithdrawAmount() external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("MIN_WITHDRAW_AMOUNT");
        PendingChange storage pc = pendingChanges[key];
        require(pc.executableAt > 0 && block.timestamp >= pc.executableAt, "Timelock not passed");
        minWithdrawAmount = pc.value;
        delete pendingChanges[key];
        emit ParameterChanged(key, pc.value);
    }

    function proposeWithdrawDelayBlocks(uint256 blocks) external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("WITHDRAW_DELAY_BLOCKS");
        pendingChanges[key] = PendingChange({
            value: blocks,
            executableAt: block.timestamp + timelockDelay,
            isAddress: false,
            addressValue: address(0)
        });
        emit ParameterProposed(key, blocks, block.timestamp + timelockDelay);
    }

    function executeWithdrawDelayBlocks() external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("WITHDRAW_DELAY_BLOCKS");
        PendingChange storage pc = pendingChanges[key];
        require(pc.executableAt > 0 && block.timestamp >= pc.executableAt, "Timelock not passed");
        withdrawDelayBlocks = pc.value;
        delete pendingChanges[key];
        emit ParameterChanged(key, pc.value);
    }

    function proposeMaxWithdrawablePercentage(uint256 pct) external onlyRole(LSP_ADMIN_ROLE) {
        require(pct <= 100, "Invalid percentage");
        bytes32 key = keccak256("MAX_WITHDRAWABLE_PERCENTAGE");
        pendingChanges[key] = PendingChange({
            value: pct,
            executableAt: block.timestamp + timelockDelay,
            isAddress: false,
            addressValue: address(0)
        });
        emit ParameterProposed(key, pct, block.timestamp + timelockDelay);
    }

    function executeMaxWithdrawablePercentage() external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("MAX_WITHDRAWABLE_PERCENTAGE");
        PendingChange storage pc = pendingChanges[key];
        require(pc.executableAt > 0 && block.timestamp >= pc.executableAt, "Timelock not passed");
        maxWithdrawablePercentage = pc.value;
        delete pendingChanges[key];
        emit ParameterChanged(key, pc.value);
    }

    function proposeMasternodeStakeAmount(uint256 amount) external onlyRole(LSP_ADMIN_ROLE) {
        require(amount >= DEFAULT_MASTERNODE_CAP, "Below min masternode cap");
        bytes32 key = keccak256("MASTERNODE_STAKE_AMOUNT");
        pendingChanges[key] = PendingChange({
            value: amount,
            executableAt: block.timestamp + timelockDelay,
            isAddress: false,
            addressValue: address(0)
        });
        emit ParameterProposed(key, amount, block.timestamp + timelockDelay);
    }

    function executeMasternodeStakeAmount() external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("MASTERNODE_STAKE_AMOUNT");
        PendingChange storage pc = pendingChanges[key];
        require(pc.executableAt > 0 && block.timestamp >= pc.executableAt, "Timelock not passed");
        masternodeStakeAmount = pc.value;
        delete pendingChanges[key];
        emit ParameterChanged(key, pc.value);
    }

    function proposeTimelockDelay(uint256 delay) external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("TIMELOCK_DELAY");
        pendingChanges[key] = PendingChange({
            value: delay,
            executableAt: block.timestamp + timelockDelay,
            isAddress: false,
            addressValue: address(0)
        });
        emit ParameterProposed(key, delay, block.timestamp + timelockDelay);
    }

    function executeTimelockDelay() external onlyRole(LSP_ADMIN_ROLE) {
        bytes32 key = keccak256("TIMELOCK_DELAY");
        PendingChange storage pc = pendingChanges[key];
        require(pc.executableAt > 0 && block.timestamp >= pc.executableAt, "Timelock not passed");
        timelockDelay = pc.value;
        delete pendingChanges[key];
        emit ParameterChanged(key, pc.value);
    }

    function proposePause() external onlyRole(LSP_ADMIN_ROLE) {
        pendingPauseAt = block.timestamp + emergencyTimelockDelay;
        emit ParameterProposed(keccak256("PAUSE"), 1, pendingPauseAt);
    }

    function executePause() external onlyRole(LSP_ADMIN_ROLE) {
        require(pendingPauseAt > 0 && block.timestamp >= pendingPauseAt, "Timelock not passed");
        pendingPauseAt = 0;
        _pause();
    }

    function proposeUnpause() external onlyRole(LSP_ADMIN_ROLE) {
        pendingUnpauseAt = block.timestamp + emergencyTimelockDelay;
        emit ParameterProposed(keccak256("UNPAUSE"), 1, pendingUnpauseAt);
    }

    function executeUnpause() external onlyRole(LSP_ADMIN_ROLE) {
        require(pendingUnpauseAt > 0 && block.timestamp >= pendingUnpauseAt, "Timelock not passed");
        pendingUnpauseAt = 0;
        _unpause();
    }

    function withdrawForValidator(uint256 amount) external onlyRole(LSP_ADMIN_ROLE) nonReentrant {
        require(amount > 0, "Amount must be > 0");
        uint256 balance = address(this).balance;
        require(amount <= balance, "Insufficient balance");
        uint256 minRequired = (totalPooledXDC * (100 - maxWithdrawablePercentage)) / 100;
        require(balance - amount >= minRequired, "Exceeds max withdrawable");
        totalPooledXDC -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer failed");
    }

    function proposeMasternode(address operator) external onlyRole(LSP_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(lspKYCSubmitted, "LSP must submit KYC first");
        require(operators[operator], "Operator not approved");
        _verifyOperatorKYC(operator);
        require(!validator.isCandidate(operator), "Already candidate");

        uint256 balance = address(this).balance;
        require(balance >= masternodeStakeAmount, "Insufficient balance for masternode");

        validator.propose{value: masternodeStakeAmount}(operator);
        totalStakedInMasternodes += masternodeStakeAmount;
        masternodeOperators[operator].push(operator);

        emit MasternodeProposed(operator, masternodeStakeAmount);
    }

    /// @dev Stake native XDC - auto-deploys masternode when 10mil+ and KYC operator ready
    function stake() external payable nonReentrant whenNotPaused {
        require(msg.value >= minStakeAmount, "Amount below minimum");
        uint256 shares = bxdcToken.previewDeposit(msg.value);
        require(shares > 0, "Invalid bXDC amount");

        totalPooledXDC += msg.value;
        bxdcToken.mint(msg.sender, shares);

        emit Staked(msg.sender, msg.value, shares, getExchangeRate());

        _tryAutoDeployMasternode();
    }

    function deposit(uint256 assets, address receiver) public nonReentrant whenNotPaused returns (uint256) {
        require(assets >= minStakeAmount, "Amount below minimum");
        IERC20(address(wxdc)).safeTransferFrom(msg.sender, address(this), assets);
        wxdc.withdraw(assets);
        totalPooledXDC += assets;
        uint256 shares = bxdcToken.previewDeposit(assets);
        bxdcToken.mint(receiver, shares);
        emit IERC4626.Deposit(msg.sender, receiver, assets, shares);
        emit Staked(receiver, assets, shares, getExchangeRate());
        _tryAutoDeployMasternode();
        return shares;
    }

    function mint(uint256 shares, address receiver) public nonReentrant whenNotPaused returns (uint256) {
        uint256 assets = bxdcToken.previewMint(shares);
        require(assets >= minStakeAmount, "Amount below minimum");
        IERC20(address(wxdc)).safeTransferFrom(msg.sender, address(this), assets);
        wxdc.withdraw(assets);
        totalPooledXDC += assets;
        bxdcToken.mint(receiver, shares);
        emit IERC4626.Deposit(msg.sender, receiver, assets, shares);
        emit Staked(receiver, assets, shares, getExchangeRate());
        _tryAutoDeployMasternode();
        return assets;
    }

    function _tryAutoDeployMasternode() internal {
        if (!lspKYCSubmitted || address(this).balance < masternodeStakeAmount) return;
        for (uint256 i = 0; i < operatorList.length; i++) {
            address op = operatorList[i];
            if (operators[op] && !validator.isCandidate(op) && address(this).balance >= masternodeStakeAmount) {
                if (address(kycVerifier) != address(0) && kycVerifier.getHashCount(op) < 1) continue;
                _proposeMasternodeInternal(op);
                break;
            }
        }
    }

    function _proposeMasternodeInternal(address operator) internal {
        if (!lspKYCSubmitted || !operators[operator] || validator.isCandidate(operator)) return;
        if (address(this).balance < masternodeStakeAmount) return;
        if (address(kycVerifier) != address(0) && kycVerifier.getHashCount(operator) < 1) return;

        validator.propose{value: masternodeStakeAmount}(operator);
        totalStakedInMasternodes += masternodeStakeAmount;
        masternodeOperators[operator].push(operator);
        emit MasternodeProposed(operator, masternodeStakeAmount);
    }

    /// @dev Resign masternode - receive() updates totalStakedInMasternodes when XDC returns from validator
    function resignMasternode(address operator) external onlyRole(LSP_ADMIN_ROLE) nonReentrant {
        require(validator.isCandidate(operator), "Not candidate");
        uint256 cap = validator.getCandidateCap(operator);
        require(cap > 0, "No cap");
        pendingResignAmount = cap;
        validator.resign(operator);
        require(pendingResignAmount == 0, "Resign transfer failed");
        emit MasternodeResigned(operator, cap);
    }

    function withdraw(uint256 bxdcAmount) external nonReentrant whenNotPaused {
        require(bxdcAmount > 0, "Amount must be > 0");
        require(bxdcToken.balanceOf(msg.sender) >= bxdcAmount, "Insufficient bXDC");
        uint256 xdcAmount = bxdcToken.convertToAssets(bxdcAmount);
        require(xdcAmount >= minWithdrawAmount, "Below min withdrawal");

        bxdcToken.burn(msg.sender, bxdcAmount);
        totalPooledXDC -= xdcAmount;

        if (xdcAmount <= instantExitBuffer) {
            instantExitBuffer -= xdcAmount;
            (bool ok, ) = payable(msg.sender).call{value: xdcAmount}("");
            require(ok, "Transfer failed");
            emit InstantExit(msg.sender, xdcAmount);
        } else {
            uint256 batchId = nextWithdrawalBatchId++;
            uint256 unlockBlock = block.number + withdrawDelayBlocks;
            withdrawalBatches[batchId] = WithdrawalBatch({
                xdcAmount: xdcAmount,
                unlockBlock: unlockBlock,
                redeemed: false
            });
            totalInUnbonding += xdcAmount;
            userWithdrawalBatches[msg.sender].push(batchId);
            withdrawalNFT.mint(msg.sender, batchId, xdcAmount);
            emit WithdrawalNFTMinted(batchId, msg.sender, xdcAmount);
        }
    }

    function redeem(uint256 shares, address receiver, address owner) public nonReentrant whenNotPaused returns (uint256) {
        uint256 assets = bxdcToken.convertToAssets(shares);
        require(assets <= instantExitBuffer, "Use withdraw for delayed redemption");
        require(assets >= minWithdrawAmount, "Below min withdrawal");

        if (msg.sender != owner) {
            IERC20(address(bxdcToken)).safeTransferFrom(owner, address(this), shares);
            bxdcToken.burn(address(this), shares);
        } else {
            bxdcToken.burn(owner, shares);
        }
        totalPooledXDC -= assets;
        instantExitBuffer -= assets;

        (bool ok, ) = payable(receiver).call{value: assets}("");
        require(ok, "Transfer failed");

        emit IERC4626.Withdraw(msg.sender, receiver, owner, assets, shares);
        emit InstantExit(receiver, assets);
        return assets;
    }

    function redeemWithdrawal(uint256 batchId) external nonReentrant {
        WithdrawalBatch storage batch = withdrawalBatches[batchId];
        require(!batch.redeemed, "Already redeemed");
        require(block.number >= batch.unlockBlock, "Still unbonding");
        uint256 amount = withdrawalNFT.balanceOf(msg.sender, batchId);
        require(amount >= batch.xdcAmount, "Insufficient NFT balance");

        batch.redeemed = true;
        totalInUnbonding -= batch.xdcAmount;
        withdrawalNFT.burn(msg.sender, batchId, batch.xdcAmount);

        (bool ok, ) = payable(msg.sender).call{value: batch.xdcAmount}("");
        require(ok, "Transfer failed");
        emit WithdrawalRedeemed(batchId, msg.sender, batch.xdcAmount);
    }

    /// @dev Handle XDC from validator (resign returns) - update totalStakedInMasternodes
    receive() external payable {
        if (msg.sender == address(validator) && pendingResignAmount > 0) {
            uint256 amount = msg.value;
            uint256 toDeduct = amount > pendingResignAmount ? pendingResignAmount : amount;
            totalStakedInMasternodes -= toDeduct;
            pendingResignAmount -= toDeduct;
        }
    }
}
