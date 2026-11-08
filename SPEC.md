# (p)IMD $pIMD - on-chain prediction market

Binding specification of one Ethereum mainnet company launch: contracts, the (p)IMD token and the website. Build exactly what is written here.

## 0. Binding rules

- ALL NUMBERS, ADDRESSES AND RULES IN THIS FILE ARE FIXED: if one cannot be met, fail the job, never change it. Every line marked "fail, don't change" carries fixed numbers.
- Adapt only what the launch rules or a reproduced finding require, each change in ADAPTATION.md. Never change rates, recipients, limits, schedules or the token, never add an owner power, pause, upgrade or minting.
- Known limitations listed in docs are accepted rules, not findings; do not change them.
- Launch kind: evm_project on Ethereum mainnet (chain 1): contracts, the (p)IMD token and its pool, then the website against the deployed addresses. (fail, don't change)

## 1. Fixed addresses (mainnet, never redeployed or modified)

- BoundaryProofVerifier 0xa19a97B522cB379c2FB846A4b18589775F674Ee9, IMD oracle INTAKE 0xa43e6F75ee006411F79Ac1C84120606C2330DE82, PoolManager 0x000000000004444c5dc75cb358380d2e3de08a90. (fail, don't change)
- USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (6 dec), IMD 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7 (18 dec), YOLO 0x49e55a87aa4bb0d2fd58fdcf1a31c9612de015dc (18 dec). (fail, don't change)
- v1 contracts (PimdRegistry 0x99BF2c49b25bdFF7bAA36A248Bd27072C90dfA35, BoundaryOracle 0x2CED79eba39EE972c6C4F7Dd51A08f28DC034555, PimdMarkets 0x6804ca9b86731056bb8e7976086c58e3e37047db): never touched, called or migrated. (fail, don't change)
- v1 contracts and token: never touched, called or migrated. (fail, don't change)
- Admin wallet 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981: the asset admin of PimdRegistry, the admin of PimdAbove and the fee admin of PimdMarkets2. (fail, don't change)

## 2. Contracts, deploy order

All in one launch transaction under 16 777 216 gas; no linked libraries, delegatecall or calls after deploy; at most 8 contracts beside the token.

1. PimdRegistry(asset admin 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981): the code of v1 PimdRegistry, changed only so: no IMD path check; no open pairs limit (Asset keeps its v1 struct for the fixed BoundaryProofVerifier, maxOpenPairs 0, never read); the asset admin replaces its immutable owner and may hand its role to a new address. (fail, don't change)
2. BoundaryOracle($contract:PimdRegistry, BoundaryProofVerifier): the code of v1 BoundaryOracle, only its registry differs: same functions, events, INTAKE, signer, BOND 10 IMD, PROOF_WINDOW 27 h, DISPUTE_WINDOW 1 h, TIMEOUT 3 days, one oracle question per hop, fee oracleCost = INTAKE price per question times hops. (fail, don't change)
3. PimdAbove($contract:PimdRegistry, $contract:BoundaryOracle, admin 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981, $owner): above markets, books, balances, fees. (fail, don't change)
4. StartOracle($contract:PimdRegistry, $contract:BoundaryOracle): start prices from 27 h after the start via the IMD oracle INTAKE 0xa43e6F75ee006411F79Ac1C84120606C2330DE82, keyed by (version, boundary). (fail, don't change)
5. PimdSwap2($contract:PimdRegistry): swaps USDC<->asset only along the version's path (1-3 Uniswap v4 pools of PoolManager 0x000000000004444c5dc75cb358380d2e3de08a90, ETH hop in the same unlock). (fail, don't change)
6. PimdMarkets2($owner, fee admin 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981, $contract:PimdRegistry, $contract:BoundaryOracle, $contract:PimdSwap2, $contract:StartOracle): markets, books, balances, fees. (fail, don't change)
- Runtime over 24 576 bytes: split PimdAbove into at most 2 contracts via $contract: args. (fail, don't change)
- Runtime over 24 576 bytes: split PimdMarkets2 into at most 3 contracts via $contract: args. (fail, don't change)
- Splits add at most 2 contracts in total, so the launch has at most 8 contracts beside the token; if more are needed, fail. (fail, don't change)
- $owner = the paying wallet: only gets all PimdAbove fees. No access to user funds, no setter.
- $owner = the paying wallet: gets all market fees, its token share and token pool fees only; no setter or access to user funds.
- Asset admin: only adds asset versions and periods in PimdRegistry and hands its role; no other power, no access to funds, no change of an existing version.

## 3. Token (copied into launch.json exactly)

- Name "(p)IMD", symbol "pIMD", 18 decimals, total supply 1 000 000 000. No constructor arguments, no owner, no mint, burn, fee, pause or upgrade. (fail, don't change)
- poolBps 3500: 35% to the pool, 10% to the swarm by the launch policy, 55% to $owner. (fail, don't change)
- Pool (p)IMD/IMD, fee 12500, tickSpacing 60, opening market cap 2 500 IMD. No application contract gets supply. (fail, don't change)
- Tokenomics: 35% pool, 10% swarm, 5% kept by $owner, 50% burned to 0x000000000000000000000000000000000000dEaD by $owner right after launch. (fail, don't change)

## 4. Registry (PimdRegistry, append-only)

- Version = token, unitsPerShare U, path of 1-3 Uniswap v4 pools from the token to USDC. Versions are numbered 1, 2, 3... over all tokens, never change or get removed; currentVersion(token) = its latest; assets lists every token once. (fail, don't change)
- Version 1, set in the constructor: IMD, U = 1 IMD, path IMD/ETH fee 10000 tickSpacing 200 (pool id 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3), ETH/USDC fee 500 tickSpacing 10 (0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27). (fail, don't change)
- configureAsset only by the asset admin, else Unauthorized. Any token except USDC and the zero address, IMD included, gets a new version with any valid U and path: no token, pool or path is hard-coded. A change of U or path = a new version: markets created later take it, existing markets keep theirs.
- Valid version, else InvalidConfiguration: U from 1e6 to 1e24 base units, a multiple of 1e6; every pool currency0 < currency1, fee <= 100000, tickSpacing > 0, hooks with initialization flags only; the path walks from the token to USDC, no currency twice. (fail, don't change)
- Periods 1 h, 1 day, 1 week (Monday 00:00 UTC), calendar month; addPeriod only by the asset admin: 5 minutes to 366 days, offset below the duration, no duplicate, at most 32. (fail, don't change)

## 5. Above markets (PimdAbove: USDC only, no token, pool or swap)

- Only admin creates a market (asset version, registry period, end boundary after now, threshold X in USD per token), else Unauthorized; no duplicate. One market per threshold and date, a ladder = several thresholds on one date. No start price.
- Pair = 1 YES + 1 NO, backed by exactly 1 USDC; split(n) n USDC into n YES + n NO, merge(n) back. Shares have 6 decimals. (fail, don't change)
- Close = the version's price at the end boundary in BoundaryOracle. YES wins if close > X, NO if close < X: a winner redeems 1 USDC, a loser 0. Close = X, or no close 3 days after the end: every share redeems 0.5 USDC. (fail, don't change)
- YES and NO books, price p USDC per share, 0.0001 to 0.9999, tick 0.0001. Buy N at p locks exactly N*p USDC, fee inside: spends at most the lock, gets (amount - fee)/p shares, stops at N shares; a limit price includes the fee. Sell N locks only those N shares, never a free balance; gets N*p minus the fee. (fail, don't change)
- Buy with Sell of the same side moves shares; Buy YES with Buy NO mints pairs, Sell YES with Sell NO burns pairs, exactly 1 USDC each. (fail, don't change)
- The maker (earlier order) fills at exactly its price, its fee inside; the taker (later order) pays or gets the rest of 1 USDC within its limit, else both rest. (fail, don't change)
- The gap between the taker's limit and its fill (unused lock on a buy, proceeds over the limit on a sell) goes in its coin to the transaction sender: the taker when its new order fills, else the match(market) caller. Resting orders match only via match(market), by anyone, any time.
- Price then time priority, partial fills, up to 64 fills per transaction, 1024 per order. Market orders: size or USDC amount + worst price; the unfilled rest returns in that transaction. Min order N*p >= 1 USDC; a partly filled order's rest under it is cancelled in that transaction, lock refunded. Limit expiry user-set, >= 5 minutes; a fill skips an expired order and moves its lock to its owner's free balance in that transaction. Cancel any time. Claim also cancels the caller's orders there. (fail, don't change)
- Orders, fills, split and merge go on after the end until settlement, orders placed before it stay live; from settlement only cancel, claim and withdraw.
- Internal USDC balance: deposit credits exactly the amount received, else reverts; deposit and withdraw free balance any time.
- Fee (none on cancel, expiry, split, merge, claim) = k*(1-q) of the amount in USDC to $owner, q = the actual fill price per share (taker: cost or proceeds per share) clamped 0.01..0.99: taker k = K = 0.05, maker k = Km = 0.01, no rebate. Only admin sets K <= 0.10 and Km <= 0.05, over a cap reverts, event, for later fills only; it may hand its role to a new address, no other power. (fail, don't change)
- Example: Vika's resting buy 10 YES at 0.4 (lock 4 USDC), Bob's market buy NO for 6 USDC, worst 0.62: 9.8 pairs. Bob q = 0.6, fee 0.12, gets 9.8 NO. Vika q = 0.4, pays 3.9437, fee 0.0237, gets 9.8 YES; her 0.0563 USDC rest under the min is refunded. $owner gets 0.1437. X = 3: close 3.01 pays Vika 9.8 USDC, close 3 pays 4.9 each. (fail, don't change)

## 6. Up/Down markets (PimdMarkets2)

### Markets
- Asset = any token with a registry version; no own list or hard-coded token. A market pins registry.currentVersion(token) at creation forever, U = its unitsPerShare.
- Market = (asset version, registry period and its boundaries, start).
- Pair = 1 UP + 1 DOWN, backed by exactly 1 USDC + U asset token. A winner redeems 1 USDC + U, a loser 0. Shares have 6 decimals. (fail, don't change)
- Settlement = the version's close in BoundaryOracle: UP wins if close > strike, DOWN if close < strike. Close = strike, or no close 3 days after the end: every share redeems 0.5 USDC + U/2. (fail, don't change)

### Price to beat (strike)
- Strike = the asset price at the exact start second, as BoundaryOracle proves a boundary. No other price or later hour, no time limit.
- Under 27 h: the first market action (any order, split or activate) proves it via BoundaryOracle in that transaction. (fail, don't change)
- 27 h or more: activate(market) calls StartOracle.request(version, start, firstBlock), which asks the IMD oracle with BoundaryOracle's checks and records the answer; the caller names only firstBlock; a refused or failed request records nothing, repeatable. (fail, don't change)
- The activate caller alone pays the total of BoundaryOracle.oracleCost(version) and gas, no fund.
- A BoundaryOracle price is a strike only if its boundary has no proposal. StartOracle prices never settle a market.
- The strike is stored once; the end does not move. Until it is stored: no orders, split or merge; no freeze or void before the end.
- At most one price proof per order transaction.

### Trading
- Orders, fills, split and merge go on after the end until settlement, orders placed before it stay live; from settlement only cancel, claim and withdraw.
- UP book: price a, USDC per UP share; DOWN book: d, asset token per DOWN share. Any price > 0, tick 0.0001 of the coin. (fail, don't change)
- Buy UP N at a locks exactly N*a USDC, buy DOWN N at d exactly N*d token, fee inside: it spends at most the lock, gets (amount - fee)/price shares, stops at N shares; a limit price includes the fee.
- Sell N UP (DOWN) locks only those N shares, never a free balance; the seller gets N*a USDC (N*d token) minus the fee.
- Buy with Sell of the same side moves shares, no swap. Buy UP with Buy DOWN mints pairs, Sell UP with Sell DOWN burns pairs, exactly 1 USDC + U each. (fail, don't change)
- The maker (earlier order) fills at exactly its price, its fee inside. The taker (later order) pays or receives the rest in its coin, swapping the missing or surplus coin via PimdSwap2 in that transaction within its limit; else nothing swaps or reverts, both orders rest. (fail, don't change)
- A mint takes from the taker's lock exactly swap + pairs + fee.
- The gap between the taker's limit and its fill (unused lock on a buy, proceeds over the limit on a sell) goes in its coin to the transaction sender: the taker when its new order fills, else the match(market) caller. Resting orders match only via match(market), by anyone, any time.
- Price then time priority, partial fills, up to 64 fills per transaction, 1024 per order. Market orders: size + worst price; the unfilled rest returns in that transaction. (fail, don't change)
- Min order: N*a >= 1 USDC for UP; N*d*P >= 1 USD for DOWN. A partly filled order's rest under it is cancelled in that transaction, lock refunded. (fail, don't change)
- Limit expiry: user-set, >= 5 minutes; a fill skips an expired order, moving its lock to the owner's free balance in that transaction. Cancel any time. Claim also cancels the caller's orders there. (fail, don't change)
- split(n): n USDC + n*U token into n UP + n DOWN; merge(n) back.
- Balances: internal USDC and each asset token; deposit credits exactly the amount received, else reverts; deposit and withdraw free balance any time.

### Fees (none on cancel, expiry, split, merge, claim)
- P = USD per asset token, path pools' slot0 once per transaction before any swap, S = U*P, V = 1 + S. q = a/V (UP), d*P/V (DOWN), clamped to 0.01..0.99, at the actual fill price (taker: cost or proceeds per share with its swap). (fail, don't change)
- Fee = k*(1-q) of the amount in its coin to $owner: taker k = K = 0.05, maker k = Km = 0.01. (fail, don't change)
- Only fee admin sets K <= 0.10 and Km <= 0.05, over a cap reverts, event, for later fills only; it may hand its role to a new address, no other power. (fail, don't change)
- Examples, IMD version 1, U = 1, P = 2.6758, swap cost = IMD out*P/(0.99*0.9995) USDC: (fail, don't change)
- Taker buys 5 DOWN from an ask at 0.5 IMD: q = 0.364, pays 2.5 IMD, fee 0.0795, gets 4.841 DOWN; the maker gets 2.4051 IMD after fee 0.0154. (fail, don't change)
- Match: resting buy 5 DOWN at 0.5 IMD, new buy 5 UP limit 2.45 USDC. Maker pays 2.5 IMD, fee 0.0159, gets 4.9682 DOWN. Taker gets 4.9682 UP for 11.8999 USDC: 4.9682 pairs, 6.7175 swapped into 2.4841 IMD, fee 0.2143; 0.0318 UP rest under the min: 0.3501 USDC back to it. (fail, don't change)

## 7. Tests (Foundry, mainnet fork)

### Registry, oracle and above markets
- Version 1 exactly as above; the asset admin adds IMD version 2 with path IMD/ETH 10000 tickSpacing 200, ETH/USDC 3000 tickSpacing 60: version 1 unchanged, currentVersion(IMD) = 2. (fail, don't change)
- configureAsset and addPeriod from any other address, $owner included, revert Unauthorized; role handover; IMD version 3 with another U leaves version 2 unchanged. (fail, don't change)
- YOLO 0x49e55a87aa4bb0d2fd58fdcf1a31c9612de015dc with path YOLO/IMD 12500 tickSpacing 60 hooks 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000, IMD/ETH 10000 tickSpacing 200, ETH/USDC 500 tickSpacing 10 accepted; every invalid case reverts. (fail, don't change)
- BoundaryOracle proves a boundary price for IMD versions 1 and 2 and YOLO, an unknown version reverts, oracleCost as above. (fail, don't change)
- PimdAbove: create by any non-admin reverts Unauthorized; YES and NO payouts, tie and no close after 3 days 0.5 / 0.5; the example to 4 decimals for both sides' fees; mint, move and burn fills; orders before the end filling after it; expired order skipped, lock to owner's free balance; sub-min rest auto-cancelled; rates and role only by admin, over a cap reverts, a new rate only for later fills. (fail, don't change)

### Up/Down markets and token
- Every rule; both examples to 4 decimals, each value rounded alone, path mocked to their P and swap cost; token split 35/10/55, pool, 50% burn after launch. (fail, don't change)
- Strike proved under 27 h, at 27 h and 30 days only via StartOracle from a mocked answer, wrong firstBlock refused, unchallenged proposal ignored; orders before the end filling after it; pool short of the limit; sandwich within the limit; third-party match; rounding never under-collateralizes a pair or locks more than the price. (fail, don't change)
- Assets IMD (version 1) and YOLO (path YOLO/IMD 12500 tickSpacing 60 hooks 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000, then the 2 pools of IMD version 1; U = 1 and 10 000 YOLO): mint, burn, tie, swap over the limit, fee-on-transfer deposit reverts. (fail, don't change)
- IMD version 2 (other path): older markets keep version 1, new ones take 2. (fail, don't change)

## 8. Website (built against the deployed addresses of this launch, Ethereum mainnet)

- All addresses, numbers and texts are fixed; if a step cannot be met, fail instead of changing them.
- Every trade and every page reads PimdMarkets2, PimdRegistry and BoundaryOracle of this launch through public RPCs; the site stores, signs and relays nothing. (fail, don't change)
- Page "Above" reads PimdAbove of this launch: per date every threshold "IMD above $X" is its own market with YES and NO prices in USDC (price = chance); buy and sell YES or NO in USDC with "Locks", the fee inside it and the shares after the fee; the money field shows the USDC balance with Max, an amount above the balance is blocked in plain English; after the end YES, NO, or 0.5 / 0.5 for a tie or no close. (fail, don't change)
- Asset picker lists every asset of that PimdRegistry; DOWN prices, balances, Max and payouts are shown in that asset's token.
- Order form: UP priced in USDC, DOWN priced in the asset token; shows "Locks" = exactly the price times shares, the fee inside it, the shares or proceeds after the fee, and the money field shows the balance with Max; an amount above the balance is blocked in plain English.
- Market page shows "Price to beat <start date hour> UTC". A market 27 h past its start without a strike shows "Start price not recorded" and a "Record start price" button that calls activate, oracle fee shown, signed and paid by the wallet; then "Waiting for oracle" until the answer. After the end it shows "Ended, result pending" with the trade panel still open until settlement; orders placed before the end stay listed and live. (fail, don't change)
- Page "Old contract": reads version 1 PimdMarkets 0x6804ca9b86731056bb8e7976086c58e3e37047db, lists the wallet's free balance and open orders there, with Cancel and Withdraw buttons signed by the wallet. Version 1 is never changed. (fail, don't change)
- Crossed orders that did not match show a "Match" button that calls match, signed by the wallet, with the unused rest the caller would get.
- Docs: the (p)IMD token address and tokenomics as in the README.
- No third-party script, font or frame loads before the user presses Connect.

## 9. Deliver

- Verified contracts and token, README with these rules and tokenomics: 35% pool, 10% swarm, 5% kept by $owner, 50% burned to 0x000000000000000000000000000000000000dEaD by $owner right after launch. (fail, don't change)
- Verified contracts, README with these rules.
