// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IKYCVerifier
 * @dev Interface for KYC verification - used by LSP to verify operator KYC status
 * XDCValidator may use KYCString[addr].length; this adapter standardizes to getHashCount
 */
interface IKYCVerifier {
    /// @dev Returns number of valid KYC hashes for the address (>= 1 means KYC verified)
    function getHashCount(address _addr) external view returns (uint256);
}
