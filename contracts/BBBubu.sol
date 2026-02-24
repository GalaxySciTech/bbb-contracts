// SPDX-License-Identifier: MIT
pragma solidity =0.8.23;

import {ERC721AQueryable, ERC721A, IERC721A} from "erc721a/contracts/extensions/ERC721AQueryable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title BBBubu
 * @dev NFT contract that allows minting via XDC payment or swapping from another NFT collection
 */
contract BBBubu is ERC721AQueryable, Ownable, ReentrancyGuard {
    // Constants
    uint256 public constant PRICE = 600 ether; // 600 XDC per NFT
    uint256 public constant MAX_SUPPLY = 10000;

    // The NFT collection that can be swapped 1:1 for BBBubu
    address public constant SWAP_COLLECTION =
        0xd659E7D0390F19Db21c3e16f17fBD7F138f3b969;

    // Base URI for token metadata
    string public baseURI;

    // Default URI for unrevealed tokens
    string public defaultURI;

    // Whether the collection has been revealed
    bool public revealed = false;

    // Tracking which NFTs from the swap collection have been used
    mapping(uint256 => bool) public swappedTokens;

    // Events
    event TokensMinted(
        address indexed user,
        uint256 quantity,
        uint256 totalCost
    );
    event TokensSwapped(
        address indexed user,
        uint256[] swapTokenIds,
        uint256 quantity
    );
    event BaseURIUpdated(string newBaseURI);
    event DefaultURIUpdated(string newDefaultURI);
    event Revealed();

    using Strings for uint256;

    constructor() ERC721A("BBBubu", "BBBubu") Ownable(msg.sender) {
        baseURI = "https://benybadboy.b-cdn.net/bbbhero/";
    }

    /**
     * @dev Mint function - allows batch minting with XDC payment
     * @param quantity Number of NFTs to mint
     */
    function mint(uint256 quantity) external payable nonReentrant {
        require(quantity > 0, "Quantity must be greater than 0");

        // Cache total supply to avoid multiple SLOAD operations
        uint256 currentSupply = totalSupply();
        require(
            currentSupply + quantity <= MAX_SUPPLY,
            "Would exceed max supply"
        );

        // Calculate total cost
        uint256 totalCost;
        unchecked {
            totalCost = PRICE * quantity;
        }
        require(msg.value >= totalCost, "Insufficient payment");

        // Mint the tokens
        _mint(msg.sender, quantity);

        emit TokensMinted(msg.sender, quantity, totalCost);

        // Refund excess payment if any
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }
    }

    /**
     * @dev Swap NFTs from the specified collection 1:1 for BBBubu tokens
     * @param tokenIds Array of token IDs from the swap collection to exchange
     */
    function swapNFTs(uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length > 0, "Must provide at least one token ID");

        // Cache total supply to avoid multiple SLOAD operations
        uint256 currentSupply = totalSupply();
        require(
            currentSupply + tokenIds.length <= MAX_SUPPLY,
            "Would exceed max supply"
        );

        IERC721 swapCollection = IERC721(SWAP_COLLECTION);

        // Verify ownership and that tokens haven't been swapped before
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(
                swapCollection.ownerOf(tokenId) == msg.sender,
                "You don't own this NFT"
            );
            require(!swappedTokens[tokenId], "Token already used for swap");

            // Mark token as swapped
            swappedTokens[tokenId] = true;

            // Transfer the NFT from user to this contract
            swapCollection.transferFrom(msg.sender, address(this), tokenId);
        }

        // Mint BBBubu tokens
        _mint(msg.sender, tokenIds.length);

        emit TokensSwapped(msg.sender, tokenIds, tokenIds.length);
    }

    /**
     * @dev Check if a token from the swap collection has been used for swapping
     * @param tokenId Token ID to check
     * @return bool Whether the token has been swapped
     */
    function isTokenSwapped(uint256 tokenId) external view returns (bool) {
        return swappedTokens[tokenId];
    }

    /**
     * @dev Get the remaining supply
     * @return uint256 Number of tokens that can still be minted
     */
    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    /**
     * @dev Owner function to mint tokens for promotional purposes
     * @param to Address to mint tokens to
     * @param quantity Number of tokens to mint
     */
    function ownerMint(address to, uint256 quantity) external onlyOwner {
        require(quantity > 0, "Quantity must be greater than 0");
        require(to != address(0), "Cannot mint to zero address");

        uint256 currentSupply = totalSupply();
        require(
            currentSupply + quantity <= MAX_SUPPLY,
            "Would exceed max supply"
        );

        _mint(to, quantity);
    }

    /**
     * @dev Set the base URI for token metadata
     * @param newBaseURI New base URI
     */
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    /**
     * @dev Set the default URI for unrevealed tokens
     * @param newDefaultURI New default URI
     */
    function setDefaultURI(string calldata newDefaultURI) external onlyOwner {
        defaultURI = newDefaultURI;
        emit DefaultURIUpdated(newDefaultURI);
    }

    /**
     * @dev Reveal the collection
     */
    function reveal() external onlyOwner {
        revealed = true;
        emit Revealed();
    }

    /**
     * @dev Withdraw contract balance to owner
     */
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");

        payable(owner()).transfer(balance);
    }

    /**
     * @dev Emergency function to withdraw any ERC721 tokens sent to this contract
     * @param tokenContract Address of the ERC721 contract
     * @param tokenId Token ID to withdraw
     * @param to Address to send the token to
     */
    function emergencyWithdrawNFT(
        address tokenContract,
        uint256 tokenId,
        address to
    ) external onlyOwner {
        IERC721(tokenContract).transferFrom(address(this), to, tokenId);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Returns the starting token ID (ERC721A override)
     */
    function _startTokenId() internal pure override returns (uint256) {
        return 1;
    }

    /**
     * @dev Returns the base URI for token metadata
     */
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    /**
     * @dev Returns the token URI for a given token ID
     * @param tokenId Token ID to get URI for
     */
    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721A, IERC721A) returns (string memory) {
        require(
            _exists(tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );

        return
            bytes(baseURI).length > 0
                ? string(abi.encodePacked(baseURI, tokenId.toString(), ".jpg"))
                : defaultURI;
    }

    // ============ INTERFACE SUPPORT ============

    /**
     * @dev Returns true if this contract implements the interface defined by interfaceId
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721A, IERC721A) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
