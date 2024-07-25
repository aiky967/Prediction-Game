// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GameToken is ERC20 {
    constructor() ERC20("Game Token", "GM") {
        _mint(msg.sender, 1000000 * 10**18);   // 1M token
    }
}