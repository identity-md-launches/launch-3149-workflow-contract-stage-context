# (p)IMD $pIMD - on-chain prediction market

Ethereum mainnet (chain id 1) company launch built from SPEC.md: asset registry, boundary price oracle,
USDC "above" markets, start-price oracle, Uniswap v4 path swapper, the (p)IMD token. See
ADAPTATION.md for what differs from SPEC.md and why, and for the scope delivered so far.

## Token and tokenomics

- `LaunchToken` (`src/LaunchToken.sol`): name "(p)IMD", symbol "pIMD", 18 decimals, total supply
  1,000,000,000 (10^27 minor units) minted once to the deployer (the launch factory). No constructor
  arguments, no owner, mint, burn, fee, pause or upgrade.
- Split by the factory (poolBps 3500): 35% to the (p)IMD/IMD pool, 10% to the swarm, 55% to $owner.
  No application contract receives supply.
- Pool (p)IMD/IMD, fee 12500, tickSpacing 60, opening market cap 2,500 IMD.
- Tokenomics after launch: 35% pool, 10% swarm, 5% kept by $owner, 50% burned by $owner to
  0x000000000000000000000000000000000000dEaD right after launch. The burn is a plain transfer by
  $owner's wallet; the token has no burn function, as the launch rules require.

## Contracts, deploy order and constructor arguments

| # | Contract | Constructor | Notes |
|---|----------|-------------|-------|
| 1 | `PimdRegistry` | `(address assetAdmin)` = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981 | v1 code; no IMD path check, no open-pairs limit, admin replaces owner and may hand its role |
| 2 | `BoundaryOracle` | `($contract:PimdRegistry, 0xa19a97B522cB379c2FB846A4b18589775F674Ee9)` | v1 code, only the registry differs |
| 3 | `PimdAbove` | `($contract:PimdRegistry, $contract:BoundaryOracle, admin 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981, $owner)` | above markets |
| 4 | `StartOracle` | `($contract:PimdRegistry, $contract:BoundaryOracle)` | start prices 27 h or later via INTAKE |
| 5 | `PimdSwap2` | `($contract:PimdRegistry)` | USDC <-> asset along the version's path |
| 6 | `PimdMarkets2` | `($owner, fee admin, registry, oracle, swap, start oracle)` | **not in this commit**, see ADAPTATION.md |

All constructors are nonpayable, make no external calls and run on an empty chain. No contract uses
delegatecall, selfdestruct, proxies or linked libraries; every library function is internal.

Fixed mainnet addresses used as constants: USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, IMD
0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7, PoolManager 0x000000000004444c5dc75cb358380d2e3de08a90,
IMD oracle INTAKE 0xa43e6F75ee006411F79Ac1C84120606C2330DE82, oracle signer
0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982. v1 contracts and token are never touched or called.

## Roles and trust assumptions

- **$owner** (0x3c587eff6c96eacf7e3dcc2cff6416161386e48c): receives every PimdAbove fee as free USDC
  balance (withdraw with `withdraw`). No setter, no access to user funds, no other power.
- **Asset admin** (PimdRegistry): adds asset versions and periods, hands its role on. Cannot change an
  existing version.
- **Admin** (PimdAbove): creates markets, sets K <= 0.10 and Km <= 0.05 (in 1/10000: 1000 and 500) for
  later fills, hands its role on. No access to funds.
- No pause, upgrade or minting anywhere. Nothing needs setting after launch: every value is fixed in
  constructors or constants.

## PimdRegistry

- Version 1 in the constructor: IMD, U = 1 IMD, path IMD/ETH fee 10000 tickSpacing 200, ETH/USDC fee
  500 tickSpacing 10. Versions are numbered over all tokens and never change.
- `configureAsset`: any token except USDC and the zero address, U from 1e6 to 1e24 and a multiple of
  1e6, 1-3 pools with currency0 < currency1, fee <= 100000, tickSpacing > 0, hooks with initialization
  flags only, path from the token to USDC with no currency twice.
- Periods 0-3: 1 h, 1 day, 1 week (Monday 00:00 UTC), calendar month. `addPeriod`: 5 minutes to 366
  days, offset below the duration, no duplicate, at most 32.

## BoundaryOracle

v1 code: `prove` within 27 h with three block proofs checked by the fixed verifier; after 27 h
`propose` (BOND 10 IMD), `dispute` (asks INTAKE one question per hop, cost = INTAKE price per question
times hops, 0.5 IMD per question when INTAKE quotes nothing), `finalize` after the 1 h dispute window,
`timeout` 3 days after the boundary.

## StartOracle

- `request(version, boundary, firstBlock)`: boundary a registry boundary 27 h or more in the past, no
  price yet, no open request; the caller pays `BoundaryOracle.oracleCost(version)` in IMD and gas.
  One INTAKE question per hop, the same questions BoundaryOracle asks, consumer = StartOracle.
- Answers go through the same attestation checks as BoundaryOracle (signer, question hash, block
  window, panel, validity). `price(version, boundary)` is USD per U tokens at 18 decimals.
- A refused request reverts and records nothing; a failed one clears the slot so it can be repeated.
- StartOracle prices are strikes only; they never settle a market.

## PimdSwap2

Exact-output swaps along a version's path inside one PoolManager unlock: `exactOutput` pays the asset
for exactly N USDC, `exactOutputAsset` pays USDC for exactly N asset tokens. The caller transfers
`maxInput` and gets the unspent part back; a path short of the output or over `maxInput` reverts.

## PimdAbove (USDC only)

- Market = (asset version, registry period, end boundary after now, threshold X in USD per token at
  18 decimals, the BoundaryOracle price scale). Admin only; one market per threshold and end.
- Pair = 1 YES + 1 NO backed by exactly 1 USDC. `split`, `merge`. Shares have 6 decimals.
- Close = the version's BoundaryOracle price at the end. YES wins if close > X, NO if close < X. Tie,
  or no close 3 days after the end: every share redeems 0.5 USDC. `claim` settles, cancels the caller's
  resting orders in the market and credits the payout to the free balance.
- Books: YES buy/sell and NO buy/sell, price 0.0001-0.9999, tick 0.0001. Buy N at p locks exactly N*p,
  fee inside: it spends at most the lock, gets (amount - fee)/p shares, stops at N. Sell N locks those
  N shares, gets N*p minus the fee. Market orders: size or USDC amount plus worst price, unfilled rest
  returned in the transaction. Limit expiry >= 5 minutes.
- Fills: buy with sell of the same side moves shares; buy YES with buy NO mints pairs; sell YES with
  sell NO burns pairs, exactly 1 USDC each. The maker (earlier order) fills at exactly its price, fee
  inside; the taker pays or receives the rest of 1 USDC (mint, burn) or the maker's price (move).
- Fee = k*(1-q) of the amount, q = the fill price per share clamped 0.01..0.99; taker K = 0.05, maker
  Km = 0.01; credited to $owner; none on cancel, expiry, split, merge, claim.
- Price then time priority, partial fills, up to 64 fills per transaction, 1024 per order. Min order
  N*p >= 1 USDC; a rest under it is cancelled in that transaction with its lock refunded. An expired
  order met during matching is closed and its lock returned to its owner. `matchMarket` by anyone; the
  gap of a taker's fill goes to the transaction sender. Orders, fills, split and merge continue after
  the end until settlement; from settlement only cancel, claim and withdraw.
- Worked example of SPEC.md section 5 is `test_specExampleVikaAndBob` in `test/PimdAbove.t.sol`.

## Operational responsibilities

- **Launch (IMD's deployer, after acceptance):** deploys the token and contracts in the order above from
  the manifest step's launch.json; no initialization call is needed.
- **$owner, right after launch:** transfer 50% of the supply (500,000,000 pIMD) to
  0x000000000000000000000000000000000000dEaD; withdraw PimdAbove fees via `withdraw` when wanted.
- **Admin 0x8Ad18E99…:** `createMarket` for each ladder threshold and date; `setRates` if wanted;
  `configureAsset` and `addPeriod` in the registry.
- **Anyone:** `prove`/`propose`/`dispute`/`finalize` in BoundaryOracle so markets can settle;
  `StartOracle.request` for strikes 27 h or more after a start; `matchMarket` for crossed books.

## Build and test

```
forge build
FOUNDRY_FUZZ_SEED=0xf61a94d61a23c65275d872cb5cb122ee110973b4dc17dba3d43ecd9f90531f51 forge test
forge fmt --check
```

ABIs: `docs/abi/<Contract>.json`. Tests use mocks at the fixed mainnet addresses (see ADAPTATION.md).

## Known limitations

- PimdMarkets2 (Up/Down markets) is not in this commit; the launch is not complete without it.
- Tests are not a security audit; the contracts hold user USDC and IMD bonds and need the independent
  adversarial review before launch.
- Orderbook insertion is a linear walk; a very deep book at one price level costs the placer more gas.
