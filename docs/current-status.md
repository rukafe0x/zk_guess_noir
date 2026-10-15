# Current status

Last reviewed: 2026-09-24

Derived from the repository tree, README TODOs, integration tests, and recent commits on branch `mvp`.

## Working / implemented

- Flutter app flow: account select/create (AVNU Argent), create/join game, commit secrets, guess, local Circom prove + Garaga calldata, on-chain verify, claim reward.
- Starknet invokes with optional explicit `Account` (UI uses secure storage; tests pass accounts).
- WebSocket subscription for contract status events (`STARKNET_WSS`).
- Poseidon commitments shared via `lib/gameplay_helpers.dart`.
- Cairo `ZKPes` + Groth16 verifier sources under `contract/`.
- Circom `guess` circuit sources under `circuit/`.
- Bundled prove assets: `assets/guess_0001.zkey`, `assets/garaga_verification_key.json`.
- Headless-style **device** integration test: `integration_test/full_gameplay_test.dart` (P2 wins path, step logs, prove/verify retries, PK-only env accounts with AVNU deploy-if-missing).
- Path-based Starknet.dart + mopro Flutter bindings with Garaga calldata in mopro (`mopro_example_app3`).

## In progress / WIP

- README states the app is functional on Sepolia with **UI as work in progress**.
- Explicit README TODOs: improve UI; gasless transactions for early users; communicate apps through indexers.

## Known issues / traps

- `test/widget_test.dart` is still the default Flutter counter test; it does not match this app.
- Native ZK / FRB requires a connected Flutter device; plain VM tests cannot call mopro.
- `mopro_flutter_bindings` depends on external `../../../mopro-example-app3` — not present inside this repo.
- FRB content-hash mismatch or missing Circom witness symbol (`guessInstantiate`) after partial rebuilds.
- `.env` is listed under Flutter `assets` in `pubspec.yaml` (easy to ship secrets if committed). `.gitignore` does not list `.env`.
- Hardcoded AVNU API key in account creation UI (tests can use `AVNU_API_KEY`).
- README still mentions some outdated paths (`mopro_flutter/lib`, root `rust` garaga bridge) relative to current `mopro_flutter_bindings` + mopro garaga feature.

## Incomplete or experimental areas

- Empty `lib/src/` directory.
- No root `.github` CI workflows found.
- Gasless gameplay txs and indexer-based multi-device sync: documented as TODO, not implemented as app features in-tree.
- Legacy `SeedPhraseScreen` / `SEED_PHRASE` / `SECRET_ACCOUNT_ADDRESS` remain in `main.dart`; primary onboarding path is AVNU account creation.

## Recently changed (git)

On `mvp` (recent commits include):

- Full gameplay integration test + dual Argent PK env / AVNU deploy helpers.
- Upgrade toward mopro Garaga calldata bindings (replace older local `garaga_rs` FRB path).
- Starknet.dart / RPC 0.10.2-oriented upgrade.
- README updates for test/run and mopro integration notes.

## Likely next work

Supported only by explicit README TODOs and obvious unfinished pieces:

1. Improve UI (README TODO).
2. Gasless / paymaster-sponsored game transactions (README TODO; account deploy already sponsored).
3. Indexer-based cross-app communication (README TODO).
4. Replace or remove obsolete `test/widget_test.dart`.
5. Keep mopro / FRB native build and external `mopro-example-app3` in sync after binding upgrades.
