// SPDX-License-Identifier: MIT
pragma solidity =0.8.23;

import {ERC721AQueryable, ERC721A, IERC721A} from "erc721a/contracts/extensions/ERC721AQueryable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title Fomo3B
 * @dev NFT contract with Fomo3D-like mechanics to drive quick sales
 */
contract Fomo3B is ERC721AQueryable, Ownable, ReentrancyGuard {
    // Constants
    uint256 public constant PRICE = 600 ether;
    uint256 public constant MAX_SUPPLY = 10000;
    uint256 public constant MIN_TIME_EXTENSION = 30 minutes;
    uint256 public constant MAX_TIME_EXTENSION = 1 hours;
    uint256 public constant JACKPOT_PERCENTAGE = 50; // 50% of total collected funds go to jackpot
    uint256 public constant GAME_DURATION = 24 hours;
    uint256 public constant JACKPOT_CLAIM_PERCENTAGE = 50; // Winner claims 50% of jackpot normally

    // State variables
    uint256 public endTime;
    uint256 public jackpotAmount;
    address public lastBuyer;
    uint256 public totalCollected;
    bool public isGameActive;
    string public baseURI;
    uint256 public currentRound;

    // Events
    event GameStarted(uint256 endTime, uint256 round);
    event NFTPurchased(
        address indexed buyer,
        uint256 tokenId,
        uint256 pricePaid,
        uint256 newEndTime
    );
    event JackpotClaimed(address indexed winner, uint256 amount, uint256 round);
    event NewRoundStarted(uint256 round, uint256 endTime);
    event FundsWithdrawn(address indexed owner, uint256 amount);

    constructor() ERC721A("Fomo3B", "FOMO") Ownable(msg.sender) {
        baseURI = "https://benybadboy.b-cdn.net/bbbhero/";
    }

    /**
     * @dev Start the Fomo3D-like game with fixed 24 hour duration
     */
    function startGame() external onlyOwner {
        require(!isGameActive, "Game is already active");

        endTime = block.timestamp + GAME_DURATION;
        isGameActive = true;
        currentRound = 1;

        emit GameStarted(endTime, currentRound);
    }

    /**
     * @dev Buy NFT function - works during game and after game ends
     * @param quantity Number of NFTs to buy
     */
    function buyNFT(uint256 quantity) external payable nonReentrant {
        require(quantity > 0, "Quantity must be greater than 0");

        // Cache total supply to avoid multiple SLOAD operations
        uint256 currentSupply = totalSupply();
        require(
            currentSupply + quantity <= MAX_SUPPLY,
            "Would exceed max supply"
        );

        // Calculate total price (fixed price)
        uint256 totalPrice = PRICE * quantity;
        require(msg.value >= totalPrice, "Insufficient payment");

        // If game is active and timer hasn't expired, process game mechanics
        if (isGameActive && block.timestamp < endTime) {
            // Extend the timer - larger purchases extend more time
            uint256 timeExtension = MIN_TIME_EXTENSION +
                (((MAX_TIME_EXTENSION - MIN_TIME_EXTENSION) * quantity) / 10);

            // Cap at MAX_TIME_EXTENSION
            if (timeExtension > MAX_TIME_EXTENSION) {
                timeExtension = MAX_TIME_EXTENSION;
            }

            endTime = block.timestamp + timeExtension;
            lastBuyer = msg.sender;

            // Update jackpot and total collected
            uint256 jackpotContribution = (totalPrice * JACKPOT_PERCENTAGE) /
                100;
            jackpotAmount += jackpotContribution;
            totalCollected += totalPrice;
        }

        // Mint NFTs (always happens, even if game timer has expired)
        _mint(msg.sender, quantity);

        emit NFTPurchased(msg.sender, currentSupply, totalPrice, endTime);
    }

    /**
     * @dev Claim jackpot after round timer expires and start a new round
     * Winner gets 50% of the jackpot normally, but 100% if all NFTs are sold
     */
    function claimJackpot() external nonReentrant {
        require(isGameActive, "Game not active");
        require(block.timestamp >= endTime, "Current round still active");
        require(msg.sender == lastBuyer, "Only last buyer can claim");

        // Store current jackpot amount and round
        uint256 totalJackpot = jackpotAmount;
        uint256 round = currentRound;
        uint256 claimAmount;

        // If all NFTs are sold, winner gets 100% of jackpot
        // Otherwise, winner gets 50% of jackpot
        if (totalSupply() >= MAX_SUPPLY) {
            claimAmount = totalJackpot;
            jackpotAmount = 0;
        } else {
            claimAmount = (totalJackpot * JACKPOT_CLAIM_PERCENTAGE) / 100;
            jackpotAmount = totalJackpot - claimAmount;
        }

        // Start new round
        currentRound++;
        endTime = block.timestamp + GAME_DURATION;

        // Transfer jackpot to winner
        (bool success, ) = payable(lastBuyer).call{value: claimAmount}("");
        require(success, "Transfer failed");

        emit JackpotClaimed(lastBuyer, claimAmount, round);
        emit NewRoundStarted(currentRound, endTime);
    }

    /**
     * @dev Withdraw contract balance (owner only)
     */
    function withdrawFunds() external onlyOwner {
        uint256 withdrawAmount = address(this).balance - jackpotAmount;
        require(withdrawAmount > 0, "No funds to withdraw");

        (bool success, ) = payable(msg.sender).call{value: withdrawAmount}("");
        require(success, "Transfer failed");

        emit FundsWithdrawn(msg.sender, withdrawAmount);
    }

    /**
     * @dev Get current status of the game
     * @return _isActive Whether game is active
     * @return _endTime Time when current round ends
     * @return _jackpot Current jackpot amount
     * @return _lastBuyer Address of last buyer
     * @return _nftsSold Number of NFTs sold so far
     * @return _round Current round number
     */
    function getGameStatus()
        external
        view
        returns (
            bool _isActive,
            uint256 _endTime,
            uint256 _jackpot,
            address _lastBuyer,
            uint256 _nftsSold,
            uint256 _round
        )
    {
        return (
            isGameActive,
            endTime,
            jackpotAmount,
            lastBuyer,
            totalSupply(),
            currentRound
        );
    }

    /**
     * @dev Check remaining time in current round
     * @return Time left in seconds, 0 if round ended
     */
    function getRemainingTime() external view returns (uint256) {
        if (!isGameActive || block.timestamp >= endTime) {
            return 0;
        }
        return endTime - block.timestamp;
    }

    /**
     * @dev Override baseURI
     */
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    /**
     * @dev Set base URI (owner only)
     */
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
    }

    /**
     * @dev Check if address can receive ETH
     */
    receive() external payable {}
}
