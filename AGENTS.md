# AGENTS.md

Operational context for coding agents working on **zk_guess** (ZK ESP / ZKPES).

Scope: the whole repository. Last checked against source: 2026-09-29. Prefer current source and manifests over historical README recipes.

## Overview

Flutter mobile app for a two-player Starknet game: each player commits to a secret number (Poseidon), guesses the opponent’s number, and proves correctness with Circom Groth16 proofs + Garaga calldata on-chain. Accounts can be created via AVNU sponsored deploy (Argent).

## Stack

| Layer | Tech |
|-------|------|
| App | Flutter/Dart (SDK `^3.9.2`), `flutter_dotenv`, `flutter_secure_storage`, `poseidon` |
| Starknet | Path deps: `packages/starknet.dart` (`starknet`, `starknet_provider`, `avnu_provider`) |
| ZK / native | `mopro_flutter_bindings` (Flutter Rust Bridge 2.11.1) → external crate `mopro-example-app3` |
| On-chain | Cairo contract in `contract/` (Scarb; garaga + OpenZeppelin) |
| Circuit | `circuit/guess.circom` (Poseidon commit + equality) |

Deeper detail: [docs/architecture.md](docs/architecture.md), [docs/current-status.md](docs/current-status.md), [docs/decisions.md](docs/decisions.md).

## Repository layout (app-relevant)

```
lib/                    Flutter UI + Starknet invoke helpers
integration_test/       Full gameplay test + test_accounts.dart (Argent setup / AVNU deploy)
assets/                 guess_0001.zkey, garaga_verification_key.json, images; .env is also listed as an asset
mopro_flutter_bindings/ FFI plugin (Cargokit builds Rust → libmopro_flutter_bindings)
packages/starknet.dart/ Vendored Starknet.dart monorepo (path dependency)
contract/               ZKPes + Groth16 verifier Cairo sources
circuit/                Circom source + mopro template snippets
```

Empty/unused: `lib/src/` (empty). No root `rust/` or `rust_builder/` directories in the current tree (`rust_builder/` is gitignored).

## Architectural constraints

1. **Native ZK requires a Flutter device/desktop target** — `RustLib.init()` + Circom prove do not run in plain Dart VM unit tests.
2. **`mopro-example-app3` is outside this repo** — `mopro_flutter_bindings/rust/Cargo.toml` depends on `path = "../../../mopro-example-app3"`. Builds fail if that sibling project is missing or out of sync.
3. **FRB Dart/Rust must match** — content-hash mismatch or missing `guessInstantiate` means rebuild native libs (`flutter clean` + full run), not hot restart.
4. **Game status machine is on-chain** — after a wrong verify in `p2_verify`, status becomes `p2_turn` (verifier’s turn), not `p1_turn`. See contract `verify_intent`.
5. **Signer default** — `lib/services.dart` uses `selected_account` from secure storage unless callers pass `Account? account` (integration test does).
6. **Proof assets must stay in sync** — keep the circuit, proving key, verification key, native witness code, and on-chain verifier compatible. `copyAssetToTemp` only copies a missing file; replacing the bundled `.zkey` also requires clearing its cached temporary copy on the device.

## Commands

```bash
# Install
flutter pub get

# Analyze / lint (Dart)
flutter analyze

# Find a device for native execution
flutter devices

# Run app (needs device/emulator and configured .env)
flutter run -d <device_id>

# Full gameplay integration test (Android emulator typical)
flutter test integration_test/full_gameplay_test.dart -d <device_id>

# Contract (from contract/; tool versions in contract/.tool-versions)
scarb build
```

No root Makefile/CI workflows found. Rust Clippy for upstream mopro crates is **outside** this repo’s documented scripts.

Widget test `test/widget_test.dart` is still the Flutter counter stub and does **not** match this app.

Contract tooling currently differs across files: `.tool-versions` pins Scarb 2.14.0 and Starknet Foundry 0.57.0, while `Scarb.toml` requests `starknet` and `assert_macros` 2.16.1. Check compatibility if the build fails; do not assume the pinned toolchain has been validated.

## Do not edit by hand (generated / vendored)

- `mopro_flutter_bindings/lib/src/rust/frb_generated*.dart`
- `mopro_flutter_bindings/lib/src/rust/third_party/mopro_example_app3.dart`
- `mopro_flutter_bindings/rust/src/frb_generated.rs`
- Large generated Freezed/JSON under `packages/starknet.dart` (edit sources, regenerate there)

## Special care

- **`.env`**: loaded at startup and shipped as a Flutter asset (`pubspec.yaml`); the root `.gitignore` does not exclude it. Never commit secrets or include private keys in a distributed build; use `.env.example` for placeholders. Do not print `.env` contents or private keys in logs or agent output.
- **Hardcoded AVNU API key** in `lib/account_selection_screen.dart` and a fallback in `integration_test/test_accounts.dart` (sponsored account create). Tests may override with `AVNU_API_KEY`. Do not copy these credentials into docs or new code.
- **Commitment + prove helpers**: `lib/gameplay_helpers.dart` (shared by UI and integration test).
- **Chain invokes**: `lib/services.dart` (`create_game`, `join_game`, `write_intent`, `verify_intent`, `claim_reward`, `approve` STRK).
- **Fee buffer**: `_feeBuffer = 1.5` in services (Starknet.dart truncates fractional fee multipliers).

## Environment

Copy `.env.example` → `.env`. Required for normal app/RPC use at minimum:

- `STARKNET_NODE_URI`, `STARKNET_WSS`, `CONTRACT_ADDRESS`, `STRK_TOKEN_ADDRESS`, `AVNU_RPC`

Integration test also needs `ACCOUNT1_SEPOLIA_ARGENTX_PK`, `ACCOUNT2_SEPOLIA_ARGENTX_PK` (addresses derived; AVNU deploy if missing).

## Gameplay integration test

- `integration_test/test_accounts.dart` validates `STARKNET_NODE_URI`, `CONTRACT_ADDRESS`, `STRK_TOKEN_ADDRESS`, `AVNU_RPC`, and both private-key variables. `STARKNET_WSS` is used by the app but is not required by this test helper.
- Accounts use the helper's fixed Argent class hash, owner key, and no guardian, with `StarknetChainId.testNet`. Use matching Sepolia RPC and contract configuration; arbitrary existing wallet addresses are not accepted as inputs.
- This test submits real chain transactions, may deploy missing accounts, and needs STRK for entry fees and gas even with sponsored deployment.
- Expected P2-win path: `created -> p1_turn -> p2_verify -> p2_turn -> p1_verify -> win_p2 -> finished`. P1 guesses incorrectly; P2 guesses correctly and claims the reward.
- The test has a ten-minute timeout and retries proof generation plus verification up to five times per verification step. Inspect `[gameplay_test]` logs to identify the failing step.

## Known traps

- Hot restart after Rust/API changes → FRB content hash / `dlopen` / missing `guessInstantiate` errors. Full native rebuild + reinstall APK.
- Use an Android emulator or device for the documented integration test (native `.so` required); a plain Dart VM cannot exercise this flow.
- After AVNU deploy, accounts still need **STRK** for entry fee + gas.
- README paths mentioning `mopro_flutter/lib` or root `rust/src/api.rs` are outdated relative to current layout (`mopro_flutter_bindings` + mopro garaga feature).

## Validation after changes

| Change area | Validate |
|-------------|----------|
| Dart UI / services | `flutter analyze`; manual run on device |
| On-chain flow / ZK | `flutter test integration_test/full_gameplay_test.dart -d <device>` |
| Cairo | `scarb build` in `contract/` |
| Native bindings | Clean rebuild; confirm app starts past `RustLib.init()` |

For documentation-only changes, check source references and `git diff --check`; no device or chain run is needed. Report which checks actually ran and any missing device, toolchain, sibling crate, or environment configuration that prevented validation.

## Docs

- [docs/architecture.md](docs/architecture.md)
- [docs/current-status.md](docs/current-status.md)
- [docs/decisions.md](docs/decisions.md)
- [README.md](README.md) — human setup notes and historical build recipes
