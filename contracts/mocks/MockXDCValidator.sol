// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockXDCValidator
 * @dev Mock for testing - simulates XDC validator without KYC/propose requirements
 */
contract MockXDCValidator {
    uint256 public minCandidateCap = 10_000_000 ether;
    uint256 public minVoterCap = 1 ether;
    uint256 public candidateWithdrawDelay = 1_296_000;
    uint256 public voterWithdrawDelay = 1_296_000;

    mapping(address => bool) public isCandidate;
    mapping(address => address) public candidateOwner;
    mapping(address => uint256) public candidateCap;
    mapping(address => mapping(address => uint256)) public voterCap;

    mapping(address => uint256) public kycHashCount;

    function uploadKYC(string calldata) external {
        kycHashCount[msg.sender]++;
    }

    function getHashCount(address addr) external view returns (uint256) {
        return kycHashCount[addr];
    }

    function propose(address _candidate) external payable {
        require(msg.value >= minCandidateCap, "Below min cap");
        require(!isCandidate[_candidate], "Already candidate");
        isCandidate[_candidate] = true;
        candidateOwner[_candidate] = msg.sender;
        candidateCap[_candidate] = msg.value;
        voterCap[_candidate][msg.sender] = msg.value;
    }

    function vote(address _candidate) external payable {
        require(msg.value >= minVoterCap, "Below min voter cap");
        require(isCandidate[_candidate], "Not candidate");
        candidateCap[_candidate] += msg.value;
        voterCap[_candidate][msg.sender] += msg.value;
    }

    function unvote(address _candidate, uint256 _cap) external {}

    function resign(address _candidate) external {
        require(isCandidate[_candidate], "Not candidate");
        uint256 cap = candidateCap[_candidate];
        require(cap > 0, "No cap");
        isCandidate[_candidate] = false;
        candidateCap[_candidate] = 0;
        address owner = candidateOwner[_candidate];
        candidateOwner[_candidate] = address(0);
        (bool ok, ) = payable(owner).call{value: cap}("");
        require(ok, "Resign transfer failed");
    }
    function getCandidateOwner(address _candidate) external view returns (address) {
        return candidateOwner[_candidate];
    }
    function getCandidateCap(address _candidate) external view returns (uint256) {
        return candidateCap[_candidate];
    }
    function getVoterCap(address _candidate, address _voter) external view returns (uint256) {
        return voterCap[_candidate][_voter];
    }
}
