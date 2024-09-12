pragma solidity =0.8.23;

import {PointToken, Ownable} from "./extensions/PointToken.sol";
import {MegadropBBB} from "./MegadropBBB.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MegadropBBBV2 is Ownable, ReentrancyGuard {
    struct DropToken {
        address token;
        string name;
        string symbol;
        uint256 deployFee;
        address deployer;
        uint256 snapshotId;
    }

    DropToken[] dropTokens;

    mapping(address => mapping(uint256 => bool)) public claimed;

    address public megadropBBBV1;

    uint256 public deployFee;

    event Drop(
        address token,
        string name,
        string symbol,
        uint256 deployFee,
        address deployer,
        uint256 snapshotId
    );

    constructor() Ownable(msg.sender) {
        deployFee = 300 ether;
        megadropBBBV1 = address(0);
    }

    function drop(
        string calldata name,
        string calldata symbol
    ) external payable {
        require(msg.value >= deployFee, "MegadropBBBV2: incorrect value");
        PointToken dropToken = new PointToken(name, symbol);
        uint256 snapshotId = MegadropBBB(megadropBBBV1).clock();
        dropTokens.push(
            DropToken(
                address(dropToken),
                name,
                symbol,
                deployFee,
                msg.sender,
                snapshotId
            )
        );
        MegadropBBB(megadropBBBV1)._snapshot();

        emit Drop(
            address(dropToken),
            name,
            symbol,
            deployFee,
            msg.sender,
            snapshotId
        );
    }

    function getBuyAmount(
        uint256 index,
        uint256 amount
    ) public view returns (uint256) {
        DropToken memory dropToken = getDropToken(index);
    }

    function getSellAmount(
        uint256 index,
        uint256 amount
    ) public view returns (uint256) {
        DropToken memory dropToken = getDropToken(index);
    }

    function buy(uint256 index) external payable {
        DropToken memory dropToken = getDropToken(index);

        PointToken(dropToken.token).mint(msg.sender, 1);
    }

    function sell(uint256 index, uint256 amount) external {
        DropToken memory dropToken = getDropToken(index);

        PointToken(dropToken.token).burnFrom(msg.sender, amount);
    }

    function claim(uint256 index) external nonReentrant {
        require(!claimed[msg.sender][index], "MegadropBBBV2: already claimed");
        uint256 claimAmt = getClaimAmt(index, msg.sender);
        payable(msg.sender).transfer(claimAmt);
        claimed[msg.sender][index] = true;
    }

    function getClaimAmt(
        uint256 index,
        address account
    ) public view returns (uint256) {
        DropToken memory dropToken = getDropToken(index);
        uint256 snapshotTotalSupply = MegadropBBB(megadropBBBV1)
            .getPastTotalSupply(dropToken.snapshotId);
        if (snapshotTotalSupply == 0) {
            return 0;
        }
        uint256 snapshotAmt = MegadropBBB(megadropBBBV1).getPastVotes(
            account,
            dropToken.snapshotId
        );
        uint256 claimAmt = (dropToken.deployFee * snapshotAmt) /
            snapshotTotalSupply;
        return claimAmt;
    }

    function getDropToken(
        uint256 index
    ) public view returns (DropToken memory) {
        DropToken memory dropToken = dropTokens[index];
        require(
            dropToken.token != address(0),
            "MegadropBBBV2:  invalid drop token"
        );
        return dropToken;
    }

    function getDropTokenLength() external view returns (uint256) {
        return dropTokens.length;
    }

    function setDeployFee(uint256 _deployFee) external onlyOwner {
        deployFee = _deployFee;
    }
}
