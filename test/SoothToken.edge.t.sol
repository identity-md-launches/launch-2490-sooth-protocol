// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SoothToken} from "../src/SoothToken.sol";

/// @notice Edge cases and failure paths not covered by SoothToken.t.sol: allowance arithmetic at
///         its limits, permit signature malleability and domain binding, and boundary amounts.
contract SoothTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    SoothToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal signerKey = 0x5007;
    address internal signer;

    function setUp() public {
        signer = vm.addr(signerKey);
        vm.prank(deployer);
        token = new SoothToken();
    }

    function _digest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
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

    // ---------------------------------------------------------------------------------------------
    // Transfers at the boundaries
    // ---------------------------------------------------------------------------------------------

    function test_transferOneWei() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
    }

    function test_transferWholeSupplyPlusOneReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_transferMaxUintReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_transferToTokenContractIsAcceptedAndStuck() public {
        // Plain ERC-20 behaviour: tokens sent to the contract are held by it and nobody can move them.
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroToZeroAddressStillReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferZeroEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        token.transfer(bob, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances at the boundaries
    // ---------------------------------------------------------------------------------------------

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, alice), 1 ether);
    }

    function test_transferFromZeroAddressOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    function test_ownerNeedsAllowanceForOwnTransferFrom() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        vm.prank(deployer);
        token.approve(alice, 3 ether);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 3 ether);
        assertEq(token.allowance(deployer, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_maxMinusOneAllowanceIsDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 1 - 1 ether);
    }

    function test_approveZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(alice, 5 ether);
        token.approve(alice, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_allowanceIsPerSpender() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        assertEq(token.allowance(deployer, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_failedTransferFromKeepsAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(alice, bob, 2 ether);
        assertEq(token.allowance(alice, bob), 5 ether);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromAccounting(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, type(uint256).max - 1);
        amount = bound(amount, 0, allowance_ < SUPPLY ? allowance_ : SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance_);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.allowance(deployer, alice), allowance_ - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromAboveAllowanceReverts(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, SUPPLY - 1);
        amount = bound(amount, allowance_ + 1, type(uint256).max);
        vm.prank(deployer);
        token.approve(alice, allowance_);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance_, amount)
        );
        token.transferFrom(deployer, bob, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, alice), allowance_);
    }

    // ---------------------------------------------------------------------------------------------
    // Permit edge cases
    // ---------------------------------------------------------------------------------------------

    function test_permitAtExactDeadlineSucceeds() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, 1 ether, 0, deadline));
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 1 ether);
    }

    function test_permitMaxValueIsInfinite() public {
        vm.prank(deployer);
        token.transfer(signer, 10 ether);
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, type(uint256).max, 0, deadline));
        token.permit(signer, alice, type(uint256).max, deadline, v, r, s);
        vm.prank(alice);
        token.transferFrom(signer, bob, 10 ether);
        assertEq(token.allowance(signer, alice), type(uint256).max);
    }

    function test_permitRejectsHighSMalleatedSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, 1 ether, 0, deadline));
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(signer, alice, 1 ether, deadline, flippedV, r, highS);
        assertEq(token.nonces(signer), 0);
    }

    function test_permitRejectsInvalidV() public {
        uint256 deadline = block.timestamp + 1 hours;
        (, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, 1 ether, 0, deadline));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(signer, alice, 1 ether, deadline, 29, r, s);
    }

    function test_permitCannotApproveForZeroAddressOwner() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), alice, 1 ether, deadline, 27, bytes32(0), bytes32(0));
        assertEq(token.allowance(address(0), alice), 0);
    }

    function test_permitToZeroSpenderReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, address(0), 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(signer, address(0), 1 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 0);
    }

    function test_permitRejectsWrongSpender() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, 1 ether, 0, deadline));
        vm.expectRevert();
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
    }

    function test_permitRejectsFutureNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, 1 ether, 1, deadline));
        vm.expectRevert();
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 0);
    }

    function test_permitSignatureForOtherDeploymentIsRejected() public {
        vm.prank(deployer);
        SoothToken other = new SoothToken();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, 1 ether, 0, deadline));
        vm.expectRevert();
        other.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(other.allowance(signer, alice), 0);
    }

    function test_permitSignatureFromOtherChainIsRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digestHere = _digest(signer, alice, 1 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digestHere);
        bytes32 separatorHere = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != separatorHere);
        vm.expectRevert();
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 0);
    }

    function test_eip712DomainIsTheTokenName() public view {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = token.eip712Domain();
        assertEq(name, "Sooth Protocol");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Sooth Protocol")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    function test_permitCanBeSubmittedByAnyone() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, 2 ether, 0, deadline));
        vm.prank(bob);
        token.permit(signer, alice, 2 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 2 ether);
        assertEq(token.allowance(signer, bob), 0);
    }

    function test_sequentialPermitsUseIncrementingNonces() public {
        uint256 deadline = block.timestamp + 1 hours;
        for (uint256 n; n < 3; ++n) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, (n + 1) * 1 ether, n, deadline));
            token.permit(signer, alice, (n + 1) * 1 ether, deadline, v, r, s);
            assertEq(token.nonces(signer), n + 1);
        }
        assertEq(token.allowance(signer, alice), 3 ether);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_permitAnyValue(uint256 value, uint256 ttl) public {
        uint256 deadline = block.timestamp + bound(ttl, 0, 3650 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(signer, alice, value, 0, deadline));
        token.permit(signer, alice, value, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), value);
        assertEq(token.nonces(signer), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_permitByStrangerKeyRejected(uint256 strangerKey) public {
        strangerKey = bound(strangerKey, 1, SECP256K1_N - 1);
        vm.assume(strangerKey != signerKey);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strangerKey, _digest(signer, alice, 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(strangerKey), signer));
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
    }

    // ---------------------------------------------------------------------------------------------
    // Unknown calls
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_arbitraryCallDoesNotMoveDeployerFunds(bytes4 selector, bytes calldata args) public {
        vm.assume(
            selector != IERC20.transfer.selector && selector != IERC20.transferFrom.selector
                && selector != IERC20.approve.selector && selector != ERC20Permit.permit.selector
        );
        uint256 before = token.balanceOf(deployer);
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        // Whatever succeeded must have been a view: no balance or supply change.
        ok;
        assertEq(token.balanceOf(deployer), before);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
