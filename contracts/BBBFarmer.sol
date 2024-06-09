pragma solidity =0.8.23;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {PointToken} from "./PointToken.sol";

contract BBBFarmer {
    address public pointToken;

    address public bbb;

    uint256 public price;

    struct User {
        uint256 stake;
        uint256 last;
        uint256 point;
    }

    mapping(address => User) public users;

    address[] public userAddrs;

    constructor() {
        //mainnet
        // bbb = 0xFa4dDcFa8E3d0475f544d0de469277CF6e0A6Fd1;
        //devnet
        bbb = 0x1796a4cAf25f1a80626D8a2D26595b19b11697c9;
        price = 2570 ether;
        pointToken = address(new PointToken("Carrot", "CAR"));
        PointToken(pointToken).mint(msg.sender, 6e10 ether);
    }

    function getUserAddrsLength() external view returns (uint256) {
        return userAddrs.length;
    }

    function buy(uint256 amt) external {
        _sync(msg.sender);
        ERC20Burnable(bbb).burnFrom(msg.sender, amt * price);
        users[msg.sender].stake += amt;
    }

    function collect() external {
        _sync(msg.sender);
        User storage user = users[msg.sender];
        uint256 point = user.point;
        user.point = 0;
        PointToken(pointToken).mint(msg.sender, point * 1 ether);
    }

    function _sync(address addr) private {
        User storage user = users[addr];
        if (user.last == 0) {
            userAddrs.push(addr);
        }
        user.point += user.stake * (block.number - user.last);
        user.last = block.number;
    }

    function getPendingPoint(address addr) external view returns (uint256) {
        User memory user = users[addr];
        return user.point + user.stake * (block.number - user.last);
    }
}
