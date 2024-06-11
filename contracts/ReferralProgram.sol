pragma solidity =0.8.23;

contract ReferralProgram {
    //user => leader
    mapping(address => address) public leaders;

    //leader => referrals
    mapping(address => address[]) public referrersList;

    function register(address leader) external {
        require(leaders[msg.sender] == address(0), "already registered");
        require(leader != msg.sender, "cannot refer self");
        leaders[msg.sender] = leader;
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
}
