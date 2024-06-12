pragma solidity =0.8.23;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {PointToken} from "./PointToken.sol";
import {ERC721AQueryable, ERC721A, IERC721A} from "erc721a/contracts/extensions/ERC721AQueryable.sol";
import {ReferralProgram} from "./ReferralProgram.sol";

contract CarrotFarmer is ERC721AQueryable {
    address public pointToken;

    address public bbb;

    address public referralProgram;

    uint256 public price;

    struct User {
        uint256 last;
        uint256 point;
    }

    mapping(address => User) public users;

    address[] public userAddrs;

    constructor() ERC721A("Carrot Farmer", "Carrot Farmer") {
        //mainnet
        bbb = 0xFa4dDcFa8E3d0475f544d0de469277CF6e0A6Fd1;
        referralProgram = 0xAf103E2E469aAA90f85310fA406E9693E79f0333;
        //devnet
        // bbb = 0x1796a4cAf25f1a80626D8a2D26595b19b11697c9;
        // referralProgram = 0x2828e5DfC0C71Bb92f00fBD3d6DC9A04E24b8f87;
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
        _mint(msg.sender, amt);
    }

    function collect() external {
        _sync(msg.sender);
        User storage user = users[msg.sender];
        uint256 point = user.point;
        user.point = 0;
        PointToken(pointToken).mint(msg.sender, point * 1 ether);

        //refer prize 10%
        address leader = ReferralProgram(referralProgram).leaders(msg.sender);
        //leader must have at least 1 stake
        if (leader != address(0) && balanceOf(leader) > 0) {
            PointToken(pointToken).mint(leader, (point * 1 ether) / 10);
        }
    }

    function _sync(address addr) private {
        User storage user = users[addr];
        if (user.last == 0) {
            userAddrs.push(addr);
        }
        uint256 stake = balanceOf(addr);
        user.point += stake * (block.number - user.last);
        user.last = block.number;
    }

    function getPendingPoint(address addr) external view returns (uint256) {
        User memory user = users[addr];
        uint256 stake = balanceOf(addr);
        return user.point + stake * (block.number - user.last);
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
