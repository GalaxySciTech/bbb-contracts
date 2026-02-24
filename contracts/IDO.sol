pragma solidity =0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./extensions/IWETH.sol";
import "./extensions/PointToken.sol";

interface IUniswapV2Factory {
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
}

interface IUniswapV2Pair {
    function mint(address to) external returns (uint liquidity);
}

contract IDO is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Uniswap V2 Factory address
    address public uniswapV2Factory;
    // WETH address
    address public weth;

    // IDO Campaign structure
    struct Campaign {
        // Project token for sale
        address projectToken;
        // Token name
        string tokenName;
        // Token symbol
        string tokenSymbol;
        // Token image URL
        string tokenImage;
        // IDO creator address
        address creator;
        // Sale start time
        uint256 saleStartTime;
        // Sale end time
        uint256 saleEndTime;
        // Is liquidity added
        bool liquidityAdded;
        // LP token address
        address liquidityPair;
        // ETH collected for this campaign (minus fees and refunds)
        uint256 ethCollected;
    }

    // Array of all campaigns
    Campaign[] public campaigns;

    // Track user participation per campaign
    mapping(uint256 => mapping(address => uint256)) public userPurchases;
    // Track user claims per campaign
    mapping(uint256 => mapping(address => uint256)) public userClaims;

    // Fee settings
    uint256 public platformFeePercent = 2; // 2% platform fee
    uint256 public creatorFeePercent = 8; // 8% creator fee

    // To prevent unauthorized access
    modifier onlyCampaignActive(uint256 campaignId) {
        require(campaignId < campaigns.length, "Invalid campaign ID");
        require(
            block.timestamp >= campaigns[campaignId].saleStartTime &&
                block.timestamp <= campaigns[campaignId].saleEndTime,
            "Campaign not active"
        );
        _;
    }

    // Events
    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed projectToken,
        address indexed creator,
        string tokenName,
        string tokenSymbol,
        string tokenImage
    );
    event TokensPurchased(
        uint256 indexed campaignId,
        address indexed buyer,
        uint256 amount,
        uint256 cost
    );
    event TokensClaimed(
        uint256 indexed campaignId,
        address indexed user,
        uint256 amount
    );
    event SaleTimeUpdated(
        uint256 indexed campaignId,
        uint256 startTime,
        uint256 endTime
    );
    event PlatformFeeUpdated(
        uint256 newPlatformFeePercent,
        uint256 newCreatorFeePercent
    );
    event CreatorFeeCollected(
        uint256 indexed campaignId,
        address indexed creator,
        uint256 amount
    );
    event LiquidityAdded(
        uint256 indexed campaignId,
        address indexed pair,
        uint256 ethAmount,
        uint256 tokenAmount
    );
    event FeeCollected(uint256 indexed campaignId, uint256 amount);
    event RefundIssued(address indexed user, uint256 amount);

    constructor() Ownable(msg.sender) {
        uniswapV2Factory = 0x347D14b13a68457186b2450bb2a6c2Fd7B38352f;
        weth = 0x951857744785E80e2De051c32EE7b25f9c458C42;
    }

    /**
     * @dev Create a new IDO campaign with a new token.
     * @param _tokenName Name of the token
     * @param _tokenSymbol Symbol of the token
     * @param _tokenImage URL of the token image/logo
     * @param _saleStartTime Sale start time
     * @param _saleEndTime Sale end time
     * @return campaignId The ID of the newly created campaign
     */
    function createCampaign(
        string memory _tokenName,
        string memory _tokenSymbol,
        string memory _tokenImage,
        uint256 _saleStartTime,
        uint256 _saleEndTime
    ) external returns (uint256 campaignId) {
        require(bytes(_tokenName).length > 0, "Token name cannot be empty");
        require(bytes(_tokenSymbol).length > 0, "Token symbol cannot be empty");
        require(_saleEndTime > _saleStartTime, "Invalid sale times");

        // Create a new token but don't mint anything yet
        PointToken newToken = new PointToken(_tokenName, _tokenSymbol);

        campaigns.push(
            Campaign({
                projectToken: address(newToken),
                tokenName: _tokenName,
                tokenSymbol: _tokenSymbol,
                tokenImage: _tokenImage,
                creator: msg.sender,
                saleStartTime: _saleStartTime,
                saleEndTime: _saleEndTime,
                liquidityAdded: false,
                liquidityPair: address(0),
                ethCollected: 0
            })
        );

        campaignId = campaigns.length - 1;
        emit CampaignCreated(
            campaignId,
            address(newToken),
            msg.sender,
            _tokenName,
            _tokenSymbol,
            _tokenImage
        );

        return campaignId;
    }

    /**
     * @dev Get the number of campaigns.
     * @return Number of campaigns
     */
    function getCampaignCount() external view returns (uint256) {
        return campaigns.length;
    }

    /**
     * @dev Buy tokens with ETH for a specific campaign.
     * @param _campaignId Campaign ID
     */
    function buyTokens(
        uint256 _campaignId
    ) external payable nonReentrant onlyCampaignActive(_campaignId) {
        Campaign storage campaign = campaigns[_campaignId];

        require(block.timestamp >= campaign.saleStartTime, "Sale not started");
        require(block.timestamp <= campaign.saleEndTime, "Sale ended");
        require(msg.value > 0, "No ETH sent");

        // Fixed ratio: 1 ETH = 1,000,000 tokens
        uint256 tokensToReceive = msg.value * 1e6; // 1e6 = 1,000,000

        require(tokensToReceive > 0, "Amount too small");

        // Only record the purchase, tokens will be minted when sale finalizes
        userPurchases[_campaignId][msg.sender] += tokensToReceive;
        campaign.ethCollected += msg.value;

        emit TokensPurchased(
            _campaignId,
            msg.sender,
            tokensToReceive,
            msg.value
        );
    }

    /**
     * @dev Check if sale has ended and add liquidity if needed
     * @param _campaignId Campaign ID
     */
    function finalizeSale(uint256 _campaignId) external nonReentrant {
        require(_campaignId < campaigns.length, "Invalid campaign ID");
        Campaign storage campaign = campaigns[_campaignId];

        require(block.timestamp > campaign.saleEndTime, "Sale not ended yet");
        require(!campaign.liquidityAdded, "Already finalized");

        _addLiquidity(_campaignId);
    }

    /**
     * @dev Add liquidity to Uniswap
     * @param _campaignId Campaign ID
     */
    function _addLiquidity(uint256 _campaignId) internal {
        Campaign storage campaign = campaigns[_campaignId];

        // Only add liquidity once
        if (campaign.liquidityAdded) {
            return;
        }

        // Mark as liquidity added first (to prevent reentrancy)
        campaign.liquidityAdded = true;

        // Get ETH amount collected
        uint256 ethCollected = campaign.ethCollected;

        // If no ETH collected, do nothing
        if (ethCollected == 0) {
            return;
        }

        // Calculate platform fees (1% for platform, 4% for creator)
        uint256 platformEthFee = (ethCollected * platformFeePercent) / 100;
        uint256 creatorEthFee = (ethCollected * creatorFeePercent) / 100;
        uint256 ethForLiquidity = ethCollected - platformEthFee - creatorEthFee;

        // Calculate tokens for liquidity based on total ETH collected (before fees)
        // Using 1 ETH = 1,000,000 tokens for liquidity
        uint256 totalTokensNeeded = (ethCollected * 1e6);
        uint256 platformTokenFee = (totalTokensNeeded * platformFeePercent) /
            100;
        uint256 creatorTokenFee = (totalTokensNeeded * creatorFeePercent) / 100;
        uint256 tokensForLiquidityAfterFees = totalTokensNeeded -
            platformTokenFee -
            creatorTokenFee;

        // Mint tokens for liquidity to this contract
        PointToken(campaign.projectToken).mint(
            address(this),
            tokensForLiquidityAfterFees
        );

        // Transfer platform token fee to owner
        if (platformTokenFee > 0) {
            PointToken(campaign.projectToken).mint(owner(), platformTokenFee);
            emit FeeCollected(_campaignId, platformTokenFee);
        }

        // Transfer creator token fee to creator
        if (creatorTokenFee > 0) {
            PointToken(campaign.projectToken).mint(
                campaign.creator,
                creatorTokenFee
            );
            emit CreatorFeeCollected(
                _campaignId,
                campaign.creator,
                creatorTokenFee
            );
        }

        // We need to wrap ETH to WETH first
        IWETH(weth).deposit{value: ethForLiquidity}();

        // Transfer platform ETH fee to owner
        if (platformEthFee > 0) {
            (bool success, ) = owner().call{value: platformEthFee}("");
            require(success, "Platform ETH fee transfer failed");
            emit FeeCollected(_campaignId, platformEthFee);
        }

        // Transfer creator ETH fee to creator
        if (creatorEthFee > 0) {
            (bool success, ) = campaign.creator.call{value: creatorEthFee}("");
            require(success, "Creator ETH fee transfer failed");
            emit CreatorFeeCollected(
                _campaignId,
                campaign.creator,
                creatorEthFee
            );
        }

        // Create pair if it doesn't exist yet
        address pair = IUniswapV2Factory(uniswapV2Factory).getPair(
            weth,
            campaign.projectToken
        );
        if (pair == address(0)) {
            pair = IUniswapV2Factory(uniswapV2Factory).createPair(
                weth,
                campaign.projectToken
            );
        }

        // Send tokens and WETH to the pair
        IERC20(weth).safeTransfer(pair, ethForLiquidity);
        IERC20(campaign.projectToken).safeTransfer(
            pair,
            tokensForLiquidityAfterFees
        );

        // Initialize the pair by calling mint
        IUniswapV2Pair(pair).mint(owner());

        // Store pair address
        campaign.liquidityPair = pair;

        emit LiquidityAdded(
            _campaignId,
            pair,
            ethForLiquidity,
            tokensForLiquidityAfterFees
        );
    }

    /**
     * @dev Claim purchased tokens for a specific campaign.
     * @param _campaignId Campaign ID
     */
    function claimTokens(uint256 _campaignId) external nonReentrant {
        require(_campaignId < campaigns.length, "Invalid campaign ID");
        Campaign storage campaign = campaigns[_campaignId];

        // Can only claim if sale has ended and liquidity is added
        require(block.timestamp > campaign.saleEndTime, "Sale not ended yet");
        require(campaign.liquidityAdded, "Liquidity not added yet");

        uint256 purchasedAmount = userPurchases[_campaignId][msg.sender];
        uint256 claimedAmount = userClaims[_campaignId][msg.sender];
        uint256 remainingToClaim = purchasedAmount - claimedAmount;

        require(remainingToClaim > 0, "No tokens to claim");

        // Update state before minting (CEI pattern)
        userClaims[_campaignId][msg.sender] = purchasedAmount;

        // Mint tokens directly to user
        PointToken(campaign.projectToken).mint(msg.sender, remainingToClaim);

        emit TokensClaimed(_campaignId, msg.sender, remainingToClaim);
    }

    /**
     * @dev Check claimable amount for a user in a specific campaign.
     * @param _campaignId Campaign ID
     * @param _user Address of the user
     */
    function getClaimableAmount(
        uint256 _campaignId,
        address _user
    ) external view returns (uint256) {
        require(_campaignId < campaigns.length, "Invalid campaign ID");
        return
            userPurchases[_campaignId][_user] - userClaims[_campaignId][_user];
    }

    /**
     * @dev Update sale time for a specific campaign.
     * @param _campaignId Campaign ID
     * @param _startTime New start time
     * @param _endTime New end time
     */
    function updateSaleTime(
        uint256 _campaignId,
        uint256 _startTime,
        uint256 _endTime
    ) external onlyOwner {
        require(_campaignId < campaigns.length, "Invalid campaign ID");
        Campaign storage campaign = campaigns[_campaignId];

        require(_endTime > _startTime, "Invalid time range");
        require(
            block.timestamp < campaign.saleStartTime,
            "Sale already started"
        );
        require(_startTime > block.timestamp, "Start time must be in future");

        campaign.saleStartTime = _startTime;
        campaign.saleEndTime = _endTime;

        emit SaleTimeUpdated(_campaignId, _startTime, _endTime);
    }

    /**
     * @dev Update platform and creator fee percentages.
     * @param _newPlatformFeePercent New platform fee percentage (0-100)
     * @param _newCreatorFeePercent New creator fee percentage (0-100)
     */
    function updatePlatformFee(
        uint256 _newPlatformFeePercent,
        uint256 _newCreatorFeePercent
    ) external onlyOwner {
        require(
            _newPlatformFeePercent + _newCreatorFeePercent <= 100,
            "Total fee too high"
        );
        platformFeePercent = _newPlatformFeePercent;
        creatorFeePercent = _newCreatorFeePercent;
        emit PlatformFeeUpdated(_newPlatformFeePercent, _newCreatorFeePercent);
    }

    /**
     * @dev Update Uniswap and WETH addresses.
     * @param _uniswapV2Factory New Uniswap factory address
     * @param _weth New WETH address
     */
    function updateAddresses(
        address _uniswapV2Factory,
        address _weth
    ) external onlyOwner {
        require(_uniswapV2Factory != address(0), "Invalid Uniswap address");
        require(_weth != address(0), "Invalid WETH address");
        uniswapV2Factory = _uniswapV2Factory;
        weth = _weth;
    }

    /**
     * @dev Emergency withdraw ETH from contract.
     * @param _to Recipient address
     */
    function emergencyWithdrawETH(address payable _to) external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");

        // Reset all campaign ETH collected to prevent double-spending
        for (uint256 i = 0; i < campaigns.length; i++) {
            if (campaigns[i].ethCollected > 0) {
                campaigns[i].ethCollected = 0;
            }
        }

        (bool success, ) = _to.call{value: balance}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @dev Emergency withdraw any ERC20 token from contract.
     * @param _token Token address
     * @param _to Recipient address
     */
    function emergencyWithdrawERC20(
        address _token,
        address _to
    ) external onlyOwner {
        // Check that token is not from an active campaign
        for (uint256 i = 0; i < campaigns.length; i++) {
            if (
                campaigns[i].projectToken == _token &&
                block.timestamp <= campaigns[i].saleEndTime &&
                !campaigns[i].liquidityAdded
            ) {
                revert("Cannot withdraw tokens from active campaign");
            }
        }

        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");

        IERC20(_token).safeTransfer(_to, balance);
    }

    /**
     * @dev Get campaign details.
     * @param _campaignId Campaign ID
     */
    function getCampaign(
        uint256 _campaignId
    )
        external
        view
        returns (
            address projectToken,
            string memory tokenName,
            string memory tokenSymbol,
            string memory tokenImage,
            address creator,
            uint256 saleStartTime,
            uint256 saleEndTime,
            bool liquidityAdded,
            address liquidityPair,
            uint256 ethCollected
        )
    {
        require(_campaignId < campaigns.length, "Invalid campaign ID");
        Campaign storage campaign = campaigns[_campaignId];

        return (
            campaign.projectToken,
            campaign.tokenName,
            campaign.tokenSymbol,
            campaign.tokenImage,
            campaign.creator,
            campaign.saleStartTime,
            campaign.saleEndTime,
            campaign.liquidityAdded,
            campaign.liquidityPair,
            campaign.ethCollected
        );
    }

    /**
     * @dev Receive function to accept ETH.
     */
    receive() external payable {}
}
