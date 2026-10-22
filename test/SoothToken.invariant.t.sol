// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SoothToken} from "../src/SoothToken.sol";

/// @notice Drives SoothToken with bounded random calls from a fixed set of actors and keeps an
///         independent model (ghost balances, allowances and nonces) of what the token must hold.
///         Failure paths are exercised too: every call that must revert is checked to revert and to
///         leave state untouched.
contract SoothHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant ACTORS = 5;

    SoothToken public immutable token;

    /// @dev Actors that hold keys, so they can also sign permits. Actor 0 is the deployer.
    address[] public actors;
    uint256[] internal keys;

    /// @dev Every address that has ever been sent tokens. Recipients are drawn from `actors` plus
    ///      the token contract itself, so the set is closed and the sum below covers all holders.
    address[] public holders;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostNonce;

    uint256 public ghostSuccessfulMoves;
    uint256 public ghostExpectedReverts;
    uint256 public ghostMovedTotal;

    constructor() {
        for (uint256 i; i < ACTORS; ++i) {
            uint256 key = uint256(keccak256(abi.encode("sooth-actor", i))) % (type(uint128).max) + 1;
            keys.push(key);
            actors.push(vm.addr(key));
            holders.push(vm.addr(key));
        }
        vm.prank(actors[0]);
        token = new SoothToken();
        ghostBalance[actors[0]] = SUPPLY;
        holders.push(address(token));
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _recipient(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    // ---------------------------------------------------------------------------------------------
    // Successful paths
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostSuccessfulMoves++;
        ghostMovedTotal += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;

        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _recipient(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = allowed < ghostBalance[owner] ? allowed : ghostBalance[owner];
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));

        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostSuccessfulMoves++;
        ghostMovedTotal += amount;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint256 ttl) external {
        uint256 idx = ownerSeed % actors.length;
        address owner = actors[idx];
        address spender = _actor(spenderSeed);
        uint256 deadline = block.timestamp + bound(ttl, 0, 365 days);
        uint256 nonce = ghostNonce[owner];

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[idx], _digest(owner, spender, amount, nonce, deadline));
        token.permit(owner, spender, amount, deadline, v, r, s);

        ghostAllowance[owner][spender] = amount;
        ghostNonce[owner] = nonce + 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths: each must revert and change nothing
    // ---------------------------------------------------------------------------------------------

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 held = ghostBalance[from];
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        token.transfer(to, amount);
        ghostExpectedReverts++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        ghostExpectedReverts++;
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _recipient(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) return;
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);
        ghostExpectedReverts++;
    }

    function permitReplayOrStale(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        uint256 idx = ownerSeed % actors.length;
        address owner = actors[idx];
        if (ghostNonce[owner] == 0) return;
        address spender = _actor(spenderSeed);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 staleNonce = ghostNonce[owner] - 1;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[idx], _digest(owner, spender, amount, staleNonce, deadline));
        vm.expectRevert();
        token.permit(owner, spender, amount, deadline, v, r, s);
        ghostExpectedReverts++;
    }

    function permitExpired(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint256 age) external {
        uint256 idx = ownerSeed % actors.length;
        address owner = actors[idx];
        address spender = _actor(spenderSeed);
        if (block.timestamp == 0) return;
        uint256 deadline = block.timestamp - bound(age, 1, block.timestamp);

        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(keys[idx], _digest(owner, spender, amount, ghostNonce[owner], deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, spender, amount, deadline, v, r, s);
        ghostExpectedReverts++;
    }

    function permitWrongSigner(uint256 ownerSeed, uint256 signerSeed, uint256 spenderSeed, uint256 amount) external {
        uint256 ownerIdx = ownerSeed % actors.length;
        uint256 signerIdx = signerSeed % actors.length;
        if (ownerIdx == signerIdx) signerIdx = (signerIdx + 1) % actors.length;
        address owner = actors[ownerIdx];
        address spender = _actor(spenderSeed);
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(keys[signerIdx], _digest(owner, spender, amount, ghostNonce[owner], deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, actors[signerIdx], owner));
        token.permit(owner, spender, amount, deadline, v, r, s);
        ghostExpectedReverts++;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 30 days));
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
}

contract SoothTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SoothHandler internal handler;
    SoothToken internal token;

    function setUp() public {
        vm.warp(1_700_000_000);
        handler = new SoothHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = SoothHandler.transfer.selector;
        selectors[1] = SoothHandler.approve.selector;
        selectors[2] = SoothHandler.transferFrom.selector;
        selectors[3] = SoothHandler.permit.selector;
        selectors[4] = SoothHandler.transferTooMuch.selector;
        selectors[5] = SoothHandler.transferToZero.selector;
        selectors[6] = SoothHandler.transferFromOverAllowance.selector;
        selectors[7] = SoothHandler.permitReplayOrStale.selector;
        selectors[8] = SoothHandler.permitExpired.selector;
        selectors[9] = SoothHandler.permitWrongSigner.selector;
        selectors[10] = SoothHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The supply is fixed: nothing a holder, spender or permit signer does changes it.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Conservation: the set of possible holders is closed, so their balances sum to the supply.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @dev Every balance equals the model's: nothing moves more or less than the call says.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesMatchModel() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address h = handler.holders(i);
            assertEq(token.balanceOf(h), handler.ghostBalance(h));
        }
    }

    /// @dev Every allowance and every permit nonce equals the model's.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesAndNoncesMatchModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            assertEq(token.nonces(owner), handler.ghostNonce(owner));
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
            }
        }
    }

    /// @dev The token never holds ether and its metadata never changes.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_metadataAndNoEther() public view {
        assertEq(address(token).balance, 0);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Sooth Protocol");
        assertEq(token.symbol(), "SOOTH");
    }
}
