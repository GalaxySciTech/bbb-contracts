pragma solidity =0.8.23;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PointToken is Ownable, ERC20Burnable {
    constructor(
        string memory name,
        string memory symbol
    ) Ownable(msg.sender) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burnFrom(
        address account,
        uint256 value
    ) public override onlyOwner {
        _burn(account, value);
    }
}
