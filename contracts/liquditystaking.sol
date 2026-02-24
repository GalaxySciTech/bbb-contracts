// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "./interfaces/IXDCValidator.sol";
import "./interfaces/IKYCVerifier.sol";
import "./WXDC.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title bXDC
 * @dev ERC4626 tokenized vault - liquid staking receipt token for XDC
 * Asset: WXDC (wrapped XDC). Shares: bXDC. Value grows with staking rewards.
 */
contract bXDC is ERC4626, Ownable {
    address public stakingPool;

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only staking pool can call");
        _;
    }

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Staked XDC", "bXDC") Ownable(msg.sender) {}

    function setStakingPool(address _stakingPool) external onlyOwner {
        require(_stakingPool != address(0), "Invalid address");
        stakingPool = _stakingPool;
    }

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
 * @dev ERC-1155 NFT representing a withdrawal claim during 30-day unbonding period
 */
contract WithdrawalRequestNFT is ERC1155Supply, Ownable {
    address public stakingPool;

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "Only staking pool");
        _;
    }

    constructor() ERC1155("") Ownable(msg.sender) {}

    function setStakingPool(address _pool) external onlyOwner {
        require(_pool != address(0), "Invalid address");
        stakingPool = _pool;
    }

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
 * @dev XDC Liquid Staking Protocol - bXDC is ERC4626 vault with WXDC as asset
 * User stakes XDC (native or WXDC) -> receive bXDC shares
 */
contract XDCLiquidityStaking is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bXDC public bxdcToken;
    WXDC public wxdc;
    WithdrawalRequestNFT public withdrawalNFT;

    IXDCValidator public validator;
    IKYCVerifier public kycVerifier;

    uint256 public constant MASTERNODE_CAP = 10_000_000 ether;
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

    event Staked(address indexed user, uint256 xdcAmount, uint256 bxdcAmount, uint256 exchangeRate);
    event WithdrawalRequested(uint256 indexed batchId, address indexed user, uint256 bxdcAmount, uint256 xdcAmount);
    event WithdrawalRedeemed(uint256 indexed batchId, address indexed user, uint256 xdcAmount);
    event WithdrawalNFTMinted(uint256 indexed batchId, address indexed user, uint256 xdcAmount);
    event MasternodeProposed(address indexed operator, uint256 amount);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event RewardsDeposited(address indexed from, uint256 amount, uint256 newExchangeRate);
    event LSPKYCSubmitted(string kycHash);
    event InstantExit(address indexed user, uint256 xdcAmount);

    constructor(address _validator, address _wxdc) Ownable(msg.sender) {
        require(_validator != address(0), "Invalid validator");
        require(_wxdc != address(0), "Invalid WXDC");
        validator = IXDCValidator(_validator);
        wxdc = WXDC(payable(_wxdc));
        bxdcToken = new bXDC(IERC20(_wxdc));
        bxdcToken.setStakingPool(address(this));
        withdrawalNFT = new WithdrawalRequestNFT();
        withdrawalNFT.setStakingPool(address(this));
    }

    function setKYCVerifier(address _verifier) external onlyOwner {
        kycVerifier = IKYCVerifier(_verifier);
    }

    function setLendingProtocol(address _lending, uint256 _limit) external onlyOwner {
        lendingProtocol = _lending;
        bufferLendingLimit = _limit;
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

    function addOperator(address operator) external onlyOwner {
        _verifyOperatorKYC(operator);
        require(!operators[operator], "Already operator");
        operators[operator] = true;
        operatorList.push(operator);
        emit OperatorAdded(operator);
    }

    function removeOperator(address operator) external onlyOwner {
        require(operators[operator], "Not operator");
        operators[operator] = false;
        emit OperatorRemoved(operator);
    }

    function submitKYC(string calldata kycHash) external onlyOwner {
        validator.uploadKYC(kycHash);
        lspKYCSubmitted = true;
        emit LSPKYCSubmitted(kycHash);
    }

    function proposeMasternode(address operator) external onlyOwner nonReentrant whenNotPaused {
        require(lspKYCSubmitted, "LSP must submit KYC first");
        require(operators[operator], "Operator not approved");
        _verifyOperatorKYC(operator);
        require(!validator.isCandidate(operator), "Already candidate");

        uint256 balance = address(this).balance;
        require(balance >= MASTERNODE_CAP, "Insufficient balance for masternode");

        validator.propose{value: MASTERNODE_CAP}(operator);
        totalStakedInMasternodes += MASTERNODE_CAP;
        masternodeOperators[operator].push(operator);

        emit MasternodeProposed(operator, MASTERNODE_CAP);
    }

    /// @dev Stake native XDC - receives XDC and mints bXDC (ERC4626 shares)
    function stake() external payable nonReentrant whenNotPaused {
        require(msg.value >= minStakeAmount, "Amount below minimum");
        uint256 shares = bxdcToken.previewDeposit(msg.value);
        require(shares > 0, "Invalid bXDC amount");

        totalPooledXDC += msg.value;
        bxdcToken.mint(msg.sender, shares);

        emit Staked(msg.sender, msg.value, shares, getExchangeRate());

        if (address(this).balance >= MASTERNODE_CAP && operatorList.length > 0) {
            for (uint256 i = 0; i < operatorList.length; i++) {
                address op = operatorList[i];
                if (operators[op] && !validator.isCandidate(op) && address(this).balance >= MASTERNODE_CAP) {
                    _proposeMasternodeInternal(op);
                    break;
                }
            }
        }
    }

    /// @dev ERC4626 deposit - deposit WXDC for bXDC shares
    function deposit(uint256 assets, address receiver) public nonReentrant whenNotPaused returns (uint256) {
        require(assets >= minStakeAmount, "Amount below minimum");
        IERC20(address(wxdc)).safeTransferFrom(msg.sender, address(this), assets);
        wxdc.withdraw(assets);
        totalPooledXDC += assets;
        uint256 shares = bxdcToken.previewDeposit(assets);
        bxdcToken.mint(receiver, shares);
        emit IERC4626.Deposit(msg.sender, receiver, assets, shares);
        emit Staked(receiver, assets, shares, getExchangeRate());
        return shares;
    }

    /// @dev ERC4626 mint - mint exact bXDC shares by depositing WXDC
    function mint(uint256 shares, address receiver) public nonReentrant whenNotPaused returns (uint256) {
        uint256 assets = bxdcToken.previewMint(shares);
        require(assets >= minStakeAmount, "Amount below minimum");
        IERC20(address(wxdc)).safeTransferFrom(msg.sender, address(this), assets);
        wxdc.withdraw(assets);
        totalPooledXDC += assets;
        bxdcToken.mint(receiver, shares);
        emit IERC4626.Deposit(msg.sender, receiver, assets, shares);
        emit Staked(receiver, assets, shares, getExchangeRate());
        return assets;
    }

    function _proposeMasternodeInternal(address operator) internal {
        if (!lspKYCSubmitted || !operators[operator] || validator.isCandidate(operator)) return;
        if (address(this).balance < MASTERNODE_CAP) return;
        if (address(kycVerifier) != address(0) && kycVerifier.getHashCount(operator) < 1) return;

        validator.propose{value: MASTERNODE_CAP}(operator);
        totalStakedInMasternodes += MASTERNODE_CAP;
        masternodeOperators[operator].push(operator);
        emit MasternodeProposed(operator, MASTERNODE_CAP);
    }

    /// @dev Withdraw/redeem bXDC - instant if buffer allows, else NFT unbonding
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

    /// @dev ERC4626 redeem - instant redeem when buffer allows (returns WXDC)
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

    function depositRewards() external payable {
        require(msg.value > 0, "Reward amount must be > 0");
        totalPooledXDC += msg.value;
        emit RewardsDeposited(msg.sender, msg.value, getExchangeRate());
    }

    function addToInstantExitBuffer() external payable onlyOwner {
        instantExitBuffer += msg.value;
    }

    function setMinStakeAmount(uint256 amount) external onlyOwner {
        minStakeAmount = amount;
    }

    function setMinWithdrawAmount(uint256 amount) external onlyOwner {
        minWithdrawAmount = amount;
    }

    function setWithdrawDelayBlocks(uint256 blocks) external onlyOwner {
        withdrawDelayBlocks = blocks;
    }

    function setMaxWithdrawablePercentage(uint256 pct) external onlyOwner {
        require(pct <= 100, "Invalid percentage");
        maxWithdrawablePercentage = pct;
    }

    function withdrawForValidator(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be > 0");
        uint256 balance = address(this).balance;
        require(amount <= balance, "Insufficient balance");
        uint256 minRequired = (totalPooledXDC * (100 - maxWithdrawablePercentage)) / 100;
        uint256 withdrawn = totalPooledXDC - balance;
        require(withdrawn + amount <= totalPooledXDC - minRequired, "Exceeds max");
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Transfer failed");
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw() external onlyOwner {
        (bool ok, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(ok, "Emergency withdraw failed");
    }

    receive() external payable {}
}
