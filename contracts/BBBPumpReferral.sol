pragma solidity =0.8.23;

import {Ownable} from "./extensions/PointToken.sol";

contract BBBPumpReferral is Ownable {
    constructor() Ownable(msg.sender) {}

    struct Leader {
        bool isKol;
        uint256 kolBlock;
        uint256 userShare;
    }
    //referral => leader
    mapping(address => address) public referrersleader;

    mapping(address => Leader) public leaderMap;

    //leader => referrals
    mapping(address => address[]) public referrersList;

    function register(address leader) external {
        require(address(0) != leader, "must not 0 address");
        require(
            referrersleader[msg.sender] == address(0),
            "already registered"
        );
        require(leader != msg.sender, "cannot refer self");
        referrersleader[msg.sender] = leader;
        referrersList[leader].push(msg.sender);
    }

    function getReferrersLength(
        address leader
    ) external view returns (uint256) {
        return referrersList[leader].length;
    }

    function getReferrersList(
        address leader
    ) external view returns (address[] memory) {
        return referrersList[leader];
    }

    function setKol(address account, bool set) external onlyOwner {
        Leader storage leader = leaderMap[account];
        leader.isKol = set;
        leader.kolBlock = block.number;
        if (!set && leader.userShare > 20) {
            leader.userShare = 20;
        }
    }

    function setShare(uint256 userShare) external {
        Leader storage leader = leaderMap[msg.sender];
        uint256 maxShare = leader.isKol ? 30 : 20;
        require(userShare <= maxShare, "share must be within allowed limit");
        leader.userShare = userShare;
    }

    function getLeader(address account) external view returns (Leader memory) {
        address leader = referrersleader[account];
        return leaderMap[leader];
    }
}
