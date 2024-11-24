pragma solidity =0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ClaimRewards is Ownable {
    using SafeERC20 for IERC20;

    bytes32 public root;

    address public rewardsToken;

    mapping(address => uint256) public claimed;

    constructor() Ownable(msg.sender) {
        //main
        rewardsToken = 0xFa4dDcFa8E3d0475f544d0de469277CF6e0A6Fd1;
        root = 0x1550af0acb93933a776ef423daa87e291250020f05108c07558610c400ade8b3;
        //test
        // lmc = 0x5195b2709770180903b7aCB3841B081Ec7b6DfFf;
    }

    function setRoot(bytes32 root_) external onlyOwner {
        root = root_;
    }

    function claim(uint256 num, bytes32[] calldata proof) external {
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, num));
        require(MerkleProof.verify(proof, root, leaf), "Claim : Invalid proof");
        require(num >= claimed[msg.sender], "Claim : Invalid max");

        uint256 claimAmt = num - claimed[msg.sender];
        if (claimAmt == 0) {
            return;
        }

        IERC20(rewardsToken).transfer(msg.sender, num * 6400 ether);
        claimed[msg.sender] = num;
    }

    function withdrawERC20(address to) external onlyOwner {
        IERC20(rewardsToken).safeTransfer(
            to,
            IERC20(rewardsToken).balanceOf(address(this))
        );
    }
}
