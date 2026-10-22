// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SoothToken} from "../src/SoothToken.sol";

/// @title Deploy script for SoothToken
/// @notice Reference deployment for local forks and review. The production launch is performed
///         by IMD's deployer through the ProjectFactory, which deploys the token from the built
///         bytecode; this script is not that launch and holds no keys.
/// @dev `deploy()` takes no configuration: the token has no constructor arguments. Tests call
///      `deploy()` directly; `run()` only wraps it in a broadcast.
contract DeploySoothToken is Script {
    /// @notice Deploys the token. The whole supply goes to whoever calls the constructor, which is
    ///         this script contract when called from a test and the broadcasting account under
    ///         `run()`.
    function deploy() public returns (SoothToken token) {
        token = new SoothToken();
    }

    /// @notice Broadcast entry point for `forge script`.
    function run() external returns (SoothToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
