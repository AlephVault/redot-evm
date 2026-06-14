// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * This is a fungible token contract.
 *
 * Feel free to edit these notes accordingly, but not
 * before reading these notes first:
 *
 * Your contract should define a way to mint tokens,
 * and optionally a way to burn tokens.
 */
contract MyERC20 is ERC20, Ownable {
    constructor() ERC20("MyERC20", "SMPL") Ownable(msg.sender) {}

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function mint(address account, uint256 amount) public onlyOwner {
        _mint(account, amount);
    }
}