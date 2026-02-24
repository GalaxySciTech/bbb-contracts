// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IXDCValidator
 * @dev Interface for XDC Network validator precompiled contract (0x0000000000000000000000000000000000000088)
 * Based on XDC 2.0 Staking proposal and XDPoSChain XDCValidator
 */
interface IXDCValidator {
    function propose(address _candidate) external payable;
    function vote(address _candidate) external payable;
    function unvote(address _candidate, uint256 _cap) external;
    function resign(address _candidate) external;
    function uploadKYC(string calldata kycHash) external;

    function minCandidateCap() external view returns (uint256);
    function minVoterCap() external view returns (uint256);
    function candidateWithdrawDelay() external view returns (uint256);
    function voterWithdrawDelay() external view returns (uint256);
    function isCandidate(address _candidate) external view returns (bool);
    function getCandidateOwner(address _candidate) external view returns (address);
    function getCandidateCap(address _candidate) external view returns (uint256);
    function getVoterCap(address _candidate, address _voter) external view returns (uint256);

    /// @dev KYC verification - returns count of valid KYC hashes for address
    /// Note: XDCValidator uses KYCString[addr]; if getHashCount not available, use adapter
    function getHashCount(address _addr) external view returns (uint256);
}
