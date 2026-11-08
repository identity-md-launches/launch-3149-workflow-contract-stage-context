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
