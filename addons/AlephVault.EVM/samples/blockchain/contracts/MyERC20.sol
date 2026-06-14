// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
contract MyERC20 is ERC20 {
    /**
     * Feel free to setup your ERC20 name and symbol as you please
     * if you change your mind.
     */
    constructor() ERC20("Sample", "SMPL") {}

    /**
     * Feel free to either uncomment+modify or remove this method.
     * This one is needed if somehow you want to express that your
     * ERC20 token needs to be expressed in units other than 1 eth.
     *
     * Here, "18" means that one entire token is 1e18 (one with 18
     * zeroes). This is typically a sensible, default, and widely
     * used value to state how many decimal positions belong to one
     * single unit of the token.
     *
     * function decimals() public view virtual returns (uint8) {
     *    return 18;
     * }
     */

    /**
     * Implement your own logic to mint tokens by invoking _mint at
     * some point inside one of your methods. The invocation must be
     * like this: _mint(account, amount).
     *
     * Also, you can implement your own logic to burn those tokens.
     * The syntax is like: _burn(account, amount).
     *
     * Don't allow those operations without prior clear rules.
     */
}