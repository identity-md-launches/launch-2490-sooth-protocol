// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SoothToken} from "../src/SoothToken.sol";
import {DeploySoothToken} from "../script/DeploySoothToken.s.sol";

contract SoothTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SoothToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    function setUp() public {
        signer = vm.addr(signerKey);
        vm.prank(deployer);
        token = new SoothToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Sooth Protocol");
        assertEq(token.symbol(), "SOOTH");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Sooth Protocol");
        assertEq(token.TOKEN_SYMBOL(), "SOOTH");
        assertEq(token.TOKEN_DECIMALS(), 18);
    }

    function test_supplyConstantIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.TOTAL_SUPPLY(), 1e27);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new SoothToken();
    }

    function test_supplyGoesToWhoeverDeploys() public {
        vm.prank(bob);
        SoothToken other = new SoothToken();
        assertEq(other.balanceOf(bob), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
        assertEq(other.totalSupply(), SUPPLY);
    }

    function test_deploymentsAreIndependent() public {
        vm.prank(bob);
        SoothToken other = new SoothToken();
        assertEq(token.balanceOf(bob), 0);
        assertEq(other.balanceOf(deployer), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 1_000 ether);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        token.transfer(bob, 11 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
            assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 attempt) public {
        held = bound(held, 0, SUPPLY - 1);
        attempt = bound(attempt, held + 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, attempt));
        token.transfer(bob, attempt);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 7 ether);
        assertTrue(token.approve(alice, 7 ether));
        assertEq(token.allowance(deployer, alice), 7 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 7 ether);
        token.approve(alice, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 3 ether);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, bob, 4 ether);
        assertTrue(token.transferFrom(deployer, bob, 4 ether));
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 4 ether);
        assertEq(token.allowance(deployer, alice), 6 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 5 ether, 6 ether)
        );
        token.transferFrom(deployer, bob, 6 ether);
    }

    function test_transferFromRevertsAboveBalanceEvenWithAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 2 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(alice, bob, 2 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Permit (ERC-2612)
    // ---------------------------------------------------------------------------------------------

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowance() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 9 ether, 0, deadline));
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(signer, alice, 9 ether);
        token.permit(signer, alice, 9 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 9 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitThenTransferFrom() public {
        vm.prank(deployer);
        token.transfer(signer, 20 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 9 ether, 0, deadline));
        token.permit(signer, alice, 9 ether, deadline, v, r, s);
        vm.prank(alice);
        token.transferFrom(signer, bob, 9 ether);
        assertEq(token.balanceOf(bob), 9 ether);
        assertEq(token.balanceOf(signer), 11 ether);
    }

    function test_permitRejectsReplay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 9 ether, 0, deadline));
        token.permit(signer, alice, 9 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, alice, 9 ether, deadline, v, r, s);
    }

    function test_permitRejectsExpiredDeadline() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 9 ether, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, alice, 9 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 0);
    }

    function test_permitRejectsWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 otherKey = 0xB0B;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, _permitDigest(signer, alice, 9 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(otherKey), signer));
        token.permit(signer, alice, 9 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 0);
    }

    function test_permitRejectsTamperedValue() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, alice, 9 ether, 0, deadline));
        vm.expectRevert();
        token.permit(signer, alice, 10 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fixed supply and absence of privileged functions
    // ---------------------------------------------------------------------------------------------

    function test_noMintPathExists() public {
        address attacker = makeAddr("attacker");
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setMinter(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(deployer);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_noOwnerOrAdminFunctions() public {
        string[8] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "paused()",
            "upgradeTo(address)",
            "setOwner(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], deployer));
            assertFalse(ok, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        (bool moved,) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, alice, deployer, 1));
        assertFalse(moved);
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 50 ether));
        assertEq(token.balanceOf(bob), 50 ether);
    }

    function test_cannotSendEtherToToken() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function test_contractNameFitsTheManifest() public pure {
        assertLe(bytes("SoothToken").length, 32);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flow, as the factory performs it: send the swarm share on, then the remainder
    // ---------------------------------------------------------------------------------------------

    function test_launchFlowsMoveExactAmounts() public {
        address distributor = makeAddr("distributor");
        address claimant = makeAddr("claimant");
        address remainderTo = makeAddr("remainderTo");
        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 pool = SUPPLY * 8_000 / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        vm.startPrank(deployer);
        assertTrue(token.transfer(distributor, swarm));
        assertTrue(token.transfer(remainderTo, remainder));
        vm.stopPrank();
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(remainderTo), remainder);
        assertEq(token.balanceOf(deployer), pool);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm);
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy script
    // ---------------------------------------------------------------------------------------------

    function test_scriptDeployMintsToCaller() public {
        DeploySoothToken deployScript = new DeploySoothToken();
        SoothToken deployed = deployScript.deploy();
        assertEq(deployed.name(), "Sooth Protocol");
        assertEq(deployed.symbol(), "SOOTH");
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(deployScript)), SUPPLY);
    }
}
