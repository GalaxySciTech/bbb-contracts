// SPDX-License-Identifier: MIT
pragma solidity =0.8.23;

import {ERC721AQueryable, ERC721A, IERC721A} from "erc721a/contracts/extensions/ERC721AQueryable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title BBBHero
 * @dev NFT contract with points system and upgrade functionality
 */
contract BBBHero is ERC721AQueryable, Ownable, ReentrancyGuard {
    // Constants
    uint256 public constant PRICE = 500 ether;
    uint256 public constant MAX_SUPPLY = 10000;
    uint256 public constant UPGRADE_COST = 500 ether; // 500 XDC for upgrade

    string public defaultURI;

    string public baseURI;

    using Strings for uint256;

    // Token level tracking
    mapping(uint256 => uint256) public tokenLevel; // tokenId => level

    // User points tracking
    mapping(address => uint256) public userPoints;
    mapping(address => uint256) public lastUpdateBlock;

    // Leaderboard tracking
    address[] public pointUsers;
    mapping(address => bool) public isPointUser;

    // Events
    event PointsUpdated(address indexed user, uint256 points);
    event TokenUpgraded(uint256 indexed tokenId, uint256 newLevel);
    event TokensMinted(address indexed user, uint256 quantity);

    constructor() ERC721A("BBB Hero", "BBBH") Ownable(msg.sender) {
        baseURI = "https://benybadboy.b-cdn.net/bbbhero/";
    }

    /**
     * @dev Mint function - allows batch minting
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

        // Use unchecked for gas optimization where overflow/underflow is not a concern
        unchecked {
            require(msg.value >= PRICE * quantity, "Insufficient payment");
        }

        // Add to user tracking if new user
        _addToUserTracking(msg.sender);

        // Mint the tokens - Point update happens in _beforeTokenTransfers
        _mint(msg.sender, quantity);

        emit TokensMinted(msg.sender, quantity);
    }

    /**
     * @dev Upgrade a token to increase its point generation ability
     * @param tokenId ID of the token to upgrade
     * @param upgradeCount Number of levels to upgrade
     */
    function upgradeToken(uint256 tokenId, uint256 upgradeCount) external payable nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "Not the owner");
        require(upgradeCount > 0, "Upgrade count must be greater than 0");
        
        uint256 totalCost;
        unchecked {
            totalCost = UPGRADE_COST * upgradeCount;
        }
        require(msg.value >= totalCost, "Insufficient payment for upgrade");

        // Update points before upgrading
        _updatePoints(msg.sender);

        // Add to user tracking if new user
        _addToUserTracking(msg.sender);

        // Cache to avoid multiple storage read/writes
        uint256 newLevel;
        unchecked {
            newLevel = tokenLevel[tokenId] + upgradeCount;
        }
        tokenLevel[tokenId] = newLevel;

        emit TokenUpgraded(tokenId, newLevel);
    }

    /**
     * @dev Add user to point user tracking if not already added
     * @param user Address of the user to add
     */
    function _addToUserTracking(address user) internal {
        if (!isPointUser[user]) {
            pointUsers.push(user);
            isPointUser[user] = true;
        }
    }

    /**
     * @dev Override _beforeTokenTransfers to update points on transfer
     * This ensures when NFTs are transferred, points are updated for both sender and recipient
     */
    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId,
        uint256 quantity
    ) internal override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        // Update points for sender if it's a transfer (not minting)
        if (from != address(0)) {
            _updatePoints(from);
        }

        // Update points for recipient if it's a transfer or mint (not burning)
        if (to != address(0)) {
            _updatePoints(to);
            _addToUserTracking(to);
        }
    }

    /**
     * @dev Update user points based on their NFT holdings
     * @param user Address of the user
     */
    function _updatePoints(address user) internal {
        uint256 lastUpdate = lastUpdateBlock[user];
        if (lastUpdate == 0) {
            lastUpdateBlock[user] = block.number;
            return;
        }

        uint256 currentBlock = block.number;
        uint256 blocksPassed;

        unchecked {
            blocksPassed = currentBlock - lastUpdate;
        }

        if (blocksPassed > 0) {
            uint256 pointsToAdd = 0;
            uint256 balance = balanceOf(user);

            if (balance > 0) {
                // Get all token IDs owned by the user
                uint256[] memory tokenIds = new uint256[](balance);
                uint256 tokenIdsIdx;

                uint256 startTokenId = _startTokenId();
                uint256 nextTokenId = _nextTokenId();

                // Collect token IDs efficiently
                for (uint256 tokenId = startTokenId; tokenId < nextTokenId; ) {
                    if (_exists(tokenId) && ownerOf(tokenId) == user) {
                        tokenIds[tokenIdsIdx] = tokenId;
                        unchecked {
                            tokenIdsIdx++;
                        }
                    }
                    unchecked {
                        tokenId++;
                    }
                }

                // Calculate points efficiently
                for (uint256 i = 0; i < balance; ) {
                    unchecked {
                        // Base point (1) + additional points based on level
                        pointsToAdd +=
                            blocksPassed *
                            (1 + tokenLevel[tokenIds[i]]);
                        i++;
                    }
                }
            }

            // Cache the user points to avoid multiple storage reads
            uint256 updatedPoints;
            unchecked {
                updatedPoints = userPoints[user] + pointsToAdd;
            }

            userPoints[user] = updatedPoints;
            lastUpdateBlock[user] = currentBlock;

            emit PointsUpdated(user, updatedPoints);
        }
    }

    /**
     * @dev Get the current points for a user
     * @param user Address to check
     * @return Current points including those not yet updated
     */
    function getCurrentPoints(address user) external view returns (uint256) {
        uint256 balance = balanceOf(user);
        uint256 lastUpdate = lastUpdateBlock[user];

        if (balance == 0 || lastUpdate == 0) {
            return userPoints[user];
        }

        uint256 pendingPoints = 0;
        uint256 blocksPassed;

        unchecked {
            blocksPassed = block.number - lastUpdate;
        }

        if (blocksPassed > 0) {
            // Get tokens owned by the user
            uint256[] memory tokenIds = new uint256[](balance);
            uint256 tokenIdsIdx;

            uint256 startTokenId = _startTokenId();
            uint256 nextTokenId = _nextTokenId();

            // Collect token IDs efficiently
            for (uint256 i = startTokenId; i < nextTokenId; ) {
                if (_exists(i) && ownerOf(i) == user) {
                    tokenIds[tokenIdsIdx] = i;
                    unchecked {
                        tokenIdsIdx++;
                    }
                }
                unchecked {
                    i++;
                }
            }

            // Calculate pending points efficiently
            for (uint256 i = 0; i < balance; ) {
                unchecked {
                    pendingPoints +=
                        blocksPassed *
                        (1 + tokenLevel[tokenIds[i]]);
                    i++;
                }
            }
        }

        unchecked {
            return userPoints[user] + pendingPoints;
        }
    }

    /**
     * @dev Get the total number of users with points
     * @return Number of users with points
     */
    function getPointUsersCount() external view returns (uint256) {
        return pointUsers.length;
    }

    /**
     * @dev Get a leaderboard of users with their points (sorted by points)
     * @param startIndex Starting index for pagination
     * @param count Number of entries to return
     * @return users Array of user addresses
     * @return points Array of user points
     */
    function getLeaderboard(
        uint256 startIndex,
        uint256 count
    ) external view returns (address[] memory users, uint256[] memory points) {
        // Validate input parameters
        require(startIndex < pointUsers.length, "Start index out of bounds");

        uint256 pointUsersLength = pointUsers.length;
        uint256 endIndex;

        unchecked {
            endIndex = startIndex + count;
            if (endIndex > pointUsersLength) {
                endIndex = pointUsersLength;
            }
        }

        uint256 resultCount;
        unchecked {
            resultCount = endIndex - startIndex;
        }

        users = new address[](resultCount);
        points = new uint256[](resultCount);

        // Copy user addresses and current points to temporary arrays
        address[] memory tempUsers = new address[](resultCount);
        uint256[] memory tempPoints = new uint256[](resultCount);

        for (uint256 i = 0; i < resultCount; ) {
            address user = pointUsers[startIndex + i];
            tempUsers[i] = user;

            // Calculate current points including pending points
            tempPoints[i] = this.getCurrentPoints(user);
            unchecked {
                i++;
            }
        }

        // Sort by points (insertion sort - more efficient than bubble sort)
        for (uint256 i = 1; i < resultCount; ) {
            uint256 key = tempPoints[i];
            address keyUser = tempUsers[i];
            uint256 j = i;

            unchecked {
                j--;
            } // j = i - 1

            while (int(j) >= 0 && tempPoints[j] < key) {
                tempPoints[j + 1] = tempPoints[j];
                tempUsers[j + 1] = tempUsers[j];
                if (j > 0) {
                    unchecked {
                        j--;
                    }
                } else {
                    break;
                }
            }

            tempPoints[j + 1] = key;
            tempUsers[j + 1] = keyUser;

            unchecked {
                i++;
            }
        }

        // Return sorted arrays
        users = tempUsers;
        points = tempPoints;
    }

    /**
     * @dev Withdraw funds from the contract
     */
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdrawal failed");
    }

    /**
     * @dev Override _startTokenId to start at 0
     */
    function _startTokenId() internal pure override returns (uint256) {
        return 0;
    }

    function setBaseURI(string memory _baseURI) public onlyOwner {
        baseURI = _baseURI;
    }

    function setDefaultURI(string memory _defaultURI) public onlyOwner {
        defaultURI = _defaultURI;
    }

    function tokenURI(
        uint256 _tokenId
    ) public view override(ERC721A, IERC721A) returns (string memory) {
        require(
            _exists(_tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );

        return
            bytes(baseURI).length > 0
                ? string(abi.encodePacked(baseURI, _tokenId.toString(), ".jpg"))
                : defaultURI;
    }
}
