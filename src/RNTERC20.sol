// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract RNTERC20 is ERC20("RNT Token", "RNT"), Ownable {
    constructor() Ownable(msg.sender) {}
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
