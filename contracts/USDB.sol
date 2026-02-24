// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract USDB is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    // Miner management
    mapping(address => bool) public miners;

    // Supported staking tokens
    mapping(address => bool) public supportedTokens;

    // Modifiers
    modifier onlyMiner() {
        require(miners[msg.sender], "USDB: caller is not a miner");
        _;
    }

    modifier onlySupportedToken(address token) {
        require(supportedTokens[token], "USDB: token not supported");
        _;
    }

    constructor() ERC20("USDB", "USDB") Ownable(msg.sender) {
        addSupportedToken(0x2A8E898b6242355c290E1f4Fc966b8788729A4D4);
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    /**
     * @dev Add miner to the allowed list
     */
    function addMiner(address miner) public onlyOwner {
        require(miner != address(0), "USDB: miner cannot be zero address");
        miners[miner] = true;
    }

    /**
     * @dev Remove miner from the allowed list
     */
    function removeMiner(address miner) external onlyOwner {
        miners[miner] = false;
    }

    /**
     * @dev Miner mint tokens
     */
    function mint(address to, uint256 amount) external onlyMiner nonReentrant {
        require(to != address(0), "USDB: mint to zero address");
        require(amount > 0, "USDB: mint amount must be greater than 0");
        _mint(to, amount);
    }

    /**
     * @dev Add supported token to the whitelist
     */
    function addSupportedToken(address token) public onlyOwner {
        require(token != address(0), "USDB: token cannot be zero address");
        supportedTokens[token] = true;
    }

    /**
     * @dev Remove supported token from the whitelist
     */
    function removeSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = false;
    }

    /**
     * @dev Deposit tokens 1:1 to mint USDB
     */
    function deposit(
        address token,
        uint256 amount
    ) external onlySupportedToken(token) nonReentrant {
        require(amount > 0, "USDB: deposit amount must be greater than 0");

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }

    /**
     * @dev Owner withdraw staked tokens from contract
     */
    function withdrawToken(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(amount > 0, "USDB: withdraw amount must be greater than 0");
        require(
            IERC20(token).balanceOf(address(this)) >= amount,
            "USDB: insufficient token balance"
        );

        IERC20(token).transfer(msg.sender, amount);
    }

    /**
     * @dev Check if address is a miner
     */
    function isMiner(address account) external view returns (bool) {
        return miners[account];
    }

    /**
     * @dev Check if token is supported
     */
    function isTokenSupported(address token) external view returns (bool) {
        return supportedTokens[token];
    }
}
