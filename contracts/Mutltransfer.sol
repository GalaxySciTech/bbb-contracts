pragma solidity =0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract Mutltransfer {
    
    function batchTransferEther(
        address[] calldata tos,
        uint256[] calldata amts
    ) external {}

    function batchTransferToken(
        address token,
        address[] calldata tos,
        uint256[] calldata amts
    ) external {
        for (uint256 i = 0; i < tos.length; i++) {
            IERC20(token).transferFrom(msg.sender, tos[i], amts[i]);
        }
    }

    function batchTransferNFT(
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
