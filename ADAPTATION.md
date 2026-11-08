# Adaptations

Each change from SPEC.md that a launch rule or the build environment required, as section 0 asks.

1. **OpenZeppelin vendored under `src/vendor/`.** The launch forbids changes to `lib/`, `remappings.txt`
   and `.gitmodules`, so the OpenZeppelin v5 files the v1 contracts import are copied as ordinary files
   from the verified BoundaryOracle source bundle (`0x2CED79eba39EE972c6C4F7Dd51A08f28DC034555`) and
   imported by relative path. No OpenZeppelin code was changed (forge fmt reformatted one file).

2. **BoundaryProofVerifier reached through an interface.** The verifier is a fixed mainnet contract
   (`0xa19a97B522cB379c2FB846A4b18589775F674Ee9`) that is never redeployed, so this repository ships
   `IBoundaryProofVerifier` with the v1 `BlockProof` struct and `verify` signature instead of the
   contract's RLP and Merkle-Patricia source. BoundaryOracle's calls and ABI are unchanged.

3. **Tests run on mocks, not a mainnet fork.** The verifier builds and tests with no network, so the
   section 7 fork requirement cannot be met there. The tests etch mocks at the fixed mainnet addresses
   (USDC, IMD, YOLO, INTAKE, the signer, the PoolManager, the verifier) and run with chain id 1. Every
   number asserted (version 1, periods, fee example to 4 decimals, oracle cost, 27 h windows) is the
   spec's. A fork run against the live contracts remains to be done by review before launch.

4. **Scope delivered in this assignment.** The time budget of this run covered LaunchToken,
   PimdRegistry, BoundaryOracle, PimdAbove, StartOracle and PimdSwap2 with tests. **PimdMarkets2
   (SPEC.md section 6, Up/Down markets) is not implemented in this commit** and must be delivered
   before the launch manifest can list the six contracts of section 2. Nothing in the delivered
   contracts depends on it; PimdSwap2 and StartOracle are its dependencies and are ready.
   No spec number, rate, recipient or limit was changed.

5. **Gap rule settled per fill (review finding 8904774a).** SPEC.md section 5 gives "the gap between
   the taker's limit and its fill" to the transaction sender. The first build paid a resting taker
   buy's whole remaining lock to whoever closed it, which handed the owner's collateral for unbought
   shares to a `matchMarket` caller. Now each fill pays its own gap (limit cost minus actual cost on a
   buy; net proceeds over the limit on a sell) to the transaction sender, and a closing buy's unspent
   lock always returns to its owner. On a taker sell the fee is taken from the surplus first, so the
   seller receives min(net proceeds, n*p): the spec does not say who bears the fee inside the gap, and
   charging it to the seller could leave a low-limit seller with nothing.

6. **Live-order lists (review finding c5e99df8).** A closed order is removed from its trader's list,
   so `claim` walks resting orders only and `ordersOf` returns the live ones. The spec's "claim also
   cancels the caller's orders there" is kept.

7. **`settle` finalizes a finalizable proposal (review finding 1d8da67f).** BoundaryOracle (fixed v1
   code) lets an unchallenged proposal be finalized at any time after its deadline, which can fall in
   the same block as the boundary's 3-day timeout. PimdAbove now calls `finalize` on such a proposal
   before voiding a market, so the recorded close is used. BoundaryOracle itself is unchanged.

8. **StartOracle request TTL (review finding dfb118e4).** The spec says a failed request is
   repeatable but gives StartOracle no timeout, so an intake that accepts a request and never calls
   back blocked the (version, boundary) slot forever. An open request older than `REQUEST_TTL`
   (86,400 s, the validity the question body asks for) may be replaced; the replaced request's
   questions are void and its fee is not refunded. Constant, not a setting.

9. **Threshold unit documented (review finding 7213e581).** SPEC.md calls the threshold "USD per
   token"; BoundaryOracle records USD per `unitsPerShare` of the token. They coincide for version 1
   (U = 1 IMD). The threshold is documented and compared on BoundaryOracle's scale; no scaling is
   applied in `createMarket`, so the market id stays the hash of the admin's inputs.
