pragma solidity =0.8.23;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {PointToken} from "./PointToken.sol";
import {ERC721AQueryable, ERC721A, IERC721A} from "erc721a/contracts/extensions/ERC721AQueryable.sol";

contract BBBFarmer is ERC721AQueryable {
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

    constructor() ERC721A("Carrot Farmer", "Carrot Farmer") {
        //mainnet
        // bbb = 0xFa4dDcFa8E3d0475f544d0de469277CF6e0A6Fd1;
        //devnet
        bbb = 0x1796a4cAf25f1a80626D8a2D26595b19b11697c9;
        price = 257000 ether;
        pointToken = address(new PointToken("Carrot", "CAR"));
        PointToken(pointToken).mint(msg.sender, 1e9 ether);
    }

    function getUserAddrsLength() external view returns (uint256) {
        return userAddrs.length;
    }

    function buy(uint256 amt) external {
        _sync(msg.sender);
        ERC20Burnable(bbb).burnFrom(msg.sender, amt * price);
        users[msg.sender].stake += amt;
        _mint(msg.sender, amt);
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

    function tokenURI(
        uint256 _tokenId
    ) public view override(ERC721A, IERC721A) returns (string memory) {
        require(
            _exists(_tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );

        return
            string(
                abi.encodePacked(
                    "ipfs://bafkreiglqr6rotappwzu3vm7n3dyzb466zi34x2xu4uu56ja3bl6o7vbvy"
                )
            );
    }
}
