// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

abstract contract ERC20Snapshot is ERC20Votes {
    uint48 private _snapshotId = 1;

    event ERC20SnapshotCheckpointed(uint48 id);

    function clock() public view virtual override returns (uint48) {
        return _snapshotId;
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual override returns (string memory) {
        // Check that the clock was not modified
        if (clock() != _snapshotId) {
            revert ERC6372InconsistentClock();
        }
        return "mode=counter";
    }

    function delegates(address account) public pure override returns (address) {
        return account;
    }

    function _snapshot() public virtual returns (uint256) {
        uint48 currentId = _snapshotId++;
        emit ERC20SnapshotCheckpointed(currentId);
        return currentId;
    }
}
