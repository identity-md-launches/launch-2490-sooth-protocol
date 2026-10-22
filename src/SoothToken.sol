// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Sooth Protocol (SOOTH)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
///         deployer (`msg.sender`). There is no owner, no minter, no pause, no blocklist and no
///         fee on transfer: after deployment the contract has no privileged functions at all.
/// @dev The Solidity name `SoothToken` is the launch manifest's contract identifier. The token's
///      human-readable name and symbol are returned by `name()` and `symbol()`.
///
///      Supply is fixed by construction: the only call to `_mint` is in the constructor, and no
///      function exposes `_mint` afterwards, so `totalSupply()` can never exceed `TOTAL_SUPPLY`.
///
///      ERC-2612 `permit` is included so holders can approve spenders with a signature instead of
///      a transaction. It moves no balance and grants no privilege to anyone but the signer.
contract SoothToken is ERC20, ERC20Permit {
    /// @notice The token name returned by `name()`.
    string public constant TOKEN_NAME = "Sooth Protocol";

    /// @notice The token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "SOOTH";

    /// @notice The number of decimals returned by `decimals()`.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(TOKEN_DECIMALS);

    /// @notice Mints `TOTAL_SUPPLY` to `msg.sender` exactly once.
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain. At
    ///      launch `msg.sender` is the ProjectFactory, which then distributes the supply.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return TOKEN_DECIMALS;
    }
}
