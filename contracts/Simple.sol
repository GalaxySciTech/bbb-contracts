pragma solidity =0.8.23;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract Simple is ERC20Burnable {
    constructor() ERC20("name", "symbol") {
        _mint(msg.sender, 200 ether);
    }
}
