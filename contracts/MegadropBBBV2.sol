pragma solidity =0.8.23;

import {PointToken, Ownable} from "./extensions/PointToken.sol";
import {MegadropBBB} from "./MegadropBBB.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MegadropBBBV2 is Ownable, ReentrancyGuard {
    struct DropToken {
        uint256 index;
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

    uint256 public constant k = 2e18;

    mapping(address => mapping(address => bool)) public delegateAllowance;

    event Drop(
        uint256 index,
        address token,
        string name,
        string symbol,
        uint256 deployFee,
        address deployer,
        uint256 snapshotId
    );

    event Buy();

    event Sell();

    constructor() Ownable(msg.sender) {
        deployFee = 300 ether;
        //devnet
        megadropBBBV1 = 0xb89D5cb86f2403ca602Ee45a687437a9F0Ce1C9c;
    }

    function drop(
        string calldata name,
        string calldata symbol
    ) external payable {
        require(msg.value >= deployFee, "MegadropBBBV2: incorrect value");
        PointToken dropToken = new PointToken(name, symbol);
        uint256 snapshotId = MegadropBBB(megadropBBBV1).clock();
        uint256 index = dropTokens.length;
        dropTokens.push(
            DropToken(
                index,
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
            index,
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
        uint256 totalSupply = PointToken(dropToken.token).totalSupply();
        uint256 buyAmount = Math.sqrt(totalSupply ** 2 + k * amount) -
            totalSupply;
        return buyAmount;
    }

    function getSellAmount(
        uint256 index,
        uint256 amount
    ) public view returns (uint256) {
        DropToken memory dropToken = getDropToken(index);
        uint256 totalSupply = PointToken(dropToken.token).totalSupply();
        uint256 newTotalSupply = totalSupply - amount;
        uint256 refund = (totalSupply ** 2 - newTotalSupply ** 2) / k;
        return refund;
    }

    function buy(uint256 index) external payable {
        require(msg.value > 0, "MegadropBBBV2: value must greater than 0");
        DropToken memory dropToken = getDropToken(index);
        uint256 buyAmount = getBuyAmount(index, msg.value);
        PointToken(dropToken.token).mint(msg.sender, buyAmount);
    }

    function sell(uint256 index, uint256 amount) external nonReentrant {
        require(amount > 0, "MegadropBBBV2: amount must greater than 0");
        DropToken memory dropToken = getDropToken(index);
        uint256 refund = getSellAmount(index, amount);

        PointToken(dropToken.token).burnFrom(msg.sender, amount);
        payable(msg.sender).transfer(refund);
    }

    function claim(uint256 index, address account) external nonReentrant {
        if (!claimed[msg.sender][index]) {
            uint256 claimAmt = getClaimAmt(index, account);
            payable(account).transfer(claimAmt);
            claimed[account][index] = true;
        }
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
