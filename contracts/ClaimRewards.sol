pragma solidity =0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ClaimRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public root;

    address public rewardsToken;

    mapping(address => uint256) public claimed;

    uint256 public tokenBase;

    uint256 public ethBase;

    //0 token |1 eth
    uint256 public claimType;

    constructor() Ownable(msg.sender) {
        //main
        rewardsToken = 0xFa4dDcFa8E3d0475f544d0de469277CF6e0A6Fd1;
        root = 0x8169cf8d10ef9c58b3542c6aaac77c7faf443d4596e9fae2c3251f8e9a68139b;
        tokenBase = 10 ether;
        ethBase = 0.1 ether;
        claimType = 1;
    }

    function setRoot(bytes32 root_) external onlyOwner {
        root = root_;
    }

    function claim(
        uint256 num,
        bytes32[] calldata proof
    ) external nonReentrant {
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, num));
        require(MerkleProof.verify(proof, root, leaf), "Claim : Invalid proof");
        require(num >= claimed[msg.sender], "Claim : Invalid max");

        uint256 claimAmt = num - claimed[msg.sender];
        if (claimAmt == 0) {
            return;
        }
        if (claimType == 0) {
            IERC20(rewardsToken).transfer(msg.sender, num * tokenBase);
        }
        if (claimType == 1) {
            (bool success, ) = msg.sender.call{value: num * ethBase}("");
            require(success, "ETH transfer failed");
        }

        claimed[msg.sender] = num;
    }

    function withdrawERC20(address to) external onlyOwner nonReentrant {
        IERC20(rewardsToken).safeTransfer(
            to,
            IERC20(rewardsToken).balanceOf(address(this))
        );
    }

    function setRewardsToken(address token) external onlyOwner {
        rewardsToken = token;
    }

    function withdrawETH(address payable to) external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH balance");
        (bool success, ) = to.call{value: balance}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {}
}
