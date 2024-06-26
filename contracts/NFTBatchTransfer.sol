// SPDX-License-Identifier: MIT
pragma solidity =0.8.23;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract NFTBatchTransfer {
    function batchTransfer(
        address nftContract,
        address[] calldata recipients,
        uint256[] calldata tokenIds
    ) external {
        require(
            recipients.length == tokenIds.length,
            "Recipients and tokenIds length mismatch"
        );

        IERC721 nft = IERC721(nftContract);
        for (uint256 i = 0; i < recipients.length; i++) {
            nft.safeTransferFrom(msg.sender, recipients[i], tokenIds[i]);
        }
    }
}
