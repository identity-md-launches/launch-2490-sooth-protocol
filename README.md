# Sooth Protocol (SOOTH)

A fixed-supply ERC-20 token for launch on Robinhood Chain (chain id 4663) through IMD's
ProjectFactory as a custom token launch.

| Parameter | Value |
| --- | --- |
| Solidity contract | `SoothToken` (`src/SoothToken.sol`) |
| `name()` | `Sooth Protocol` |
| `symbol()` | `SOOTH` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 SOOTH = `1000000000000000000000000000` minor units (1e27) |
| Constructor arguments | none |
| Minting | once, in the constructor, the whole supply to `msg.sender` |
| Owner / admin | none |

## Behaviour

- **Fixed supply.** `TOTAL_SUPPLY` is minted to `msg.sender` in the constructor and nothing else
  can mint. There is no `mint`, no minter role, no owner and no upgrade path, so `totalSupply()`
  can never exceed 1e27.
- **Plain transfers.** Standard OpenZeppelin ERC-20 semantics with no fee, burn, reflection,
  blocklist, pause or transfer limit. Every transfer moves exactly the amount requested, so the
  launch flows (factory to distributor, distributor to claimants, factory to pool, pool to traders)
  arrive whole.
- **ERC-2612 permit.** Holders may approve a spender with an EIP-712 signature instead of a
  transaction. A permit only sets the signer's own allowance; it moves no balance and gives nobody
  a privilege over anyone else.
- **No privileged functions.** The contract has no owner, no pause, no blocklist, no freeze, no
  seize and no `burnFrom`. Only a holder (or a spender they approved) can move their balance.
- **No delegatecall, callcode or selfdestruct** in the runtime code (tested).

## Assumptions

- The deployer is the launch's ProjectFactory. The constructor mints to `msg.sender`, so whichever
  account creates the contract receives the whole supply. At launch that is the factory, which
  forwards the swarm's 10%, seeds the pool with 80% and sends the remaining 10% to the requester's
  `remainderTo` address. The token itself does not know or care about those addresses.
- The constructor takes no arguments and calls no other contract, so it deploys on an empty chain
  and fits the manifest without any `$factory`, `$poolManager` or `$launchNumber` argument. None are
  needed because no transfer is ever taxed, so nothing has to be exempted.
- The brief named no behaviour beyond a fixed supply; ERC-2612 permit was added as a standard,
  non-privileged convenience. It can be removed by dropping the `ERC20Permit` parent if the
  requester prefers the bare minimum.
- The token name, symbol, decimals and supply are compile-time constants. Changing any of them
  means editing `src/SoothToken.sol` and rebuilding; nothing is settable after deployment.

## Launch parameters (decided by the launch, not by this contract)

These are recorded in the manifest by the manifest step after this work is accepted. They are
listed here for reference only; do not write `launch.json` from this repository.

| Setting | Value |
| --- | --- |
| Chain | Robinhood Chain, chain id 4663 |
| Paired currency | IMD, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| Pool fee | 12500 (1.25%) |
| Tick spacing | 60 |
| `token.totalSupply` | `1000000000000000000000000000` |
| `token.decimals` | 18 |
| `token.constructorArgs` | `[]` |
| Economics | `poolBps` 8000, `initialMarketCapWei` 4000 IMD (`4000000000000000000000`), `remainderTo` `0x206f5dbf4f135c6183b5a5b99327fa0be34cb4d9` |
| Application contracts | none |

## After launch

There is nothing to configure. The token has no owner-settable values, no roles and no external
dependencies.

## Operational responsibilities

- **Requester.** Holds the 10% remainder sent to `remainderTo` and is responsible for that
  wallet's key. No on-chain action by the requester is required for the token to work.
- **Launch deployer (IMD).** Deploys the attested bytecode through the factory, distributes the
  supply and opens the pool. The token has no post-deployment steps.
- **Holders.** Each holder controls their own balance and allowances. Anyone signing a `permit`
  should set a short deadline and only sign for spenders they trust, as with any ERC-2612 token.
- **Nobody** can pause, freeze, mint, seize or upgrade. If a different supply or behaviour is ever
  wanted, it requires a new token contract and a new launch.

## Project layout

```
foundry.toml                 compiler pins: solc 0.8.26, cancun, optimizer 200 runs, bytecode_hash none
remappings.txt               forge-std and @openzeppelin/contracts
src/SoothToken.sol           the token
script/DeploySoothToken.s.sol  reference deploy script (`deploy()` is what tests call; `run()` broadcasts)
test/SoothToken.t.sol        unit and fuzz tests
lib/forge-std                 vendored forge-std 1.17.0 (plain files, no submodule)
lib/openzeppelin-contracts    vendored OpenZeppelin Contracts 5.4.0 (plain files, no submodule)
```

## Building and testing

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables and do not depend on the calling address, so they pass in any
order and in parallel. The fuzz tests pass with the verifier's seed
`FOUNDRY_FUZZ_SEED=0x808c44c99002a727138345244f850b6971ae0e0fba1863c8ba60cd203820cb18`.

## What the tests cover

- Metadata (name, symbol, decimals) and the supply constant.
- The constructor mints the whole supply to the deployer, emits one `Transfer` from the zero
  address, and separate deployments are independent.
- Transfers: exact amounts, whole balance, zero amount, self-transfer, insufficient balance,
  zero-address receiver, and fuzzed supply conservation and over-balance reverts.
- Allowances: approve, overwrite, zero spender, `transferFrom` within, without and above
  allowance, above balance, and the infinite-allowance shortcut.
- Permit: success, use via `transferFrom`, replay, expiry, wrong signer and tampered value.
- No mint path, no owner or admin functions, no privileged call that can move or freeze a holder,
  no ether acceptance, no delegatecall/callcode/selfdestruct in reachable runtime code.
- The launch flows (swarm share out, remainder out, claim) move exact amounts and leave the
  supply unchanged.
- The deploy script's `deploy()` mints to its caller.

## Security notes

Passing tests are not an audit. The contract is OpenZeppelin 5.4.0 `ERC20` + `ERC20Permit` with a
single constructor mint and a `decimals()` override, and adds no custom logic beyond that. An
independent adversarial review before release is still recommended, as for any contract that will
hold value.
