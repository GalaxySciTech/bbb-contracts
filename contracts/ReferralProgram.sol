pragma solidity =0.8.23;

contract ReferralProgram {
    //user => leader
    mapping(address => address) public leaders;

    //leader => referrals
    mapping(address => address[]) public referrersList;

    function register(address leader) external {
        require(leaders[msg.sender] == address(0), "already registered");
        leaders[msg.sender] = leader;
        referrersList[leader].push(msg.sender);
    }

    function getReferrersLength(
        address leader
    ) external view returns (uint256) {
        return referrersList[leader].length;
    }
}
