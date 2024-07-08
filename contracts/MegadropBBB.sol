pragma solidity =0.8.23;

import {ERC20Snapshot} from "./extensions/ERC20Snapshot.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20, ERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PointToken, Ownable} from "./extensions/PointToken.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MegadropBBB is ERC20Snapshot, Ownable {
    struct DropToken {
        address token;
        string name;
        string symbol;
        uint256 totalSupply;
        uint256 dropAmt;
        uint256 snapshotId;
    }
    DropToken[] dropTokens;

    IERC20 private immutable _underlying;

    uint256 public price;

    mapping(address => mapping(uint256 => bool)) public claimed;

    /**
     * @dev The underlying token couldn't be wrapped.
     */
    error ERC20InvalidUnderlying(address token);

    constructor()
        ERC20("Megadrop BBB", "mBBB")
        EIP712("mBBB", "1")
        Ownable(msg.sender)
    {
        //mainnet
        // _underlying = IERC20(0xFa4dDcFa8E3d0475f544d0de469277CF6e0A6Fd1);
        //devnet
        _underlying = IERC20(0x1796a4cAf25f1a80626D8a2D26595b19b11697c9);
        price = 257000 ether;
    }

    /**
     * @dev See {ERC20-decimals}.
     */
    function decimals() public view virtual override returns (uint8) {
        try IERC20Metadata(address(_underlying)).decimals() returns (
            uint8 value
        ) {
            return value;
        } catch {
            return super.decimals();
        }
    }

    /**
     * @dev Returns the address of the underlying ERC-20 token that is being wrapped.
     */
    function underlying() public view returns (IERC20) {
        return _underlying;
    }

    /**
     * @dev Allow a user to deposit underlying tokens and mint the corresponding number of wrapped tokens.
     */
    function depositFor(
        address account,
        uint256 value
    ) public virtual returns (bool) {
        address sender = _msgSender();
        if (sender == address(this)) {
            revert ERC20InvalidSender(address(this));
        }
        if (account == address(this)) {
            revert ERC20InvalidReceiver(account);
        }
        SafeERC20.safeTransferFrom(_underlying, sender, address(this), value);
        _mint(account, value);
        return true;
    }

    /**
     * @dev Allow a user to burn a number of wrapped tokens and withdraw the corresponding number of underlying tokens.
     */
    function withdrawTo(
        address account,
        uint256 value
    ) public virtual returns (bool) {
        if (account == address(this)) {
            revert ERC20InvalidReceiver(account);
        }
        _burn(_msgSender(), value);
        SafeERC20.safeTransfer(_underlying, account, value);
        return true;
    }

    /**
     * @dev Mint wrapped token to cover any underlyingTokens that would have been transferred by mistake. Internal
     * function that can be exposed with access control if desired.
     */
    function _recover(address account) internal virtual returns (uint256) {
        uint256 value = _underlying.balanceOf(address(this)) - totalSupply();
        _mint(account, value);
        return value;
    }

    function drop(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        uint256 dropPercent
    ) external {
        require(dropPercent <= 100, "MegadropBBB: invalid drop percent");
        PointToken dropToken = new PointToken(name, symbol);
        uint256 dropAmt = (totalSupply * dropPercent) / 100;
        uint256 mintAmt = totalSupply - dropAmt;
        if (mintAmt > 0) {
            dropToken.mint(_msgSender(), mintAmt);
        }

        if (dropAmt > 0) {
            dropTokens.push(
                DropToken(
                    address(dropToken),
                    name,
                    symbol,
                    totalSupply,
                    dropAmt,
                    clock()
                )
            );
            _snapshot();
        }

        ERC20Burnable(address(_underlying)).burnFrom(_msgSender(), price);
    }

    function claim(uint256 index) external {
        DropToken memory dropToken = dropTokens[index];
        require(!claimed[_msgSender()][index], "MegadropBBB: already claimed");
        uint256 claimAmt = getClaimAmt(index, _msgSender());
        PointToken(dropToken.token).mint(_msgSender(), claimAmt);
        claimed[_msgSender()][index] = true;
    }

    function getClaimAmt(
        uint256 index,
        address account
    ) public view returns (uint256) {
        DropToken memory dropToken = dropTokens[index];
        require(
            dropToken.token != address(0),
            "MegadropBBB: invalid drop token"
        );
        uint256 snapshotTotalSupply = getPastTotalSupply(dropToken.snapshotId);
        if (snapshotTotalSupply == 0) {
            return 0;
        }
        uint256 snapshotAmt = getPastVotes(account, dropToken.snapshotId);
        uint256 claimAmt = (dropToken.dropAmt * snapshotAmt) /
            snapshotTotalSupply;
        return claimAmt;
    }

    function getDropToken(
        uint256 index
    ) external view returns (DropToken memory) {
        return dropTokens[index];
    }

    function getDropTokenLength() external view returns (uint256) {
        return dropTokens.length;
    }
}
