# ZK Extrasensory Perception game (ZKPES)

<a href="https://www.youtube.com/watch?v=vF3sBE_SevI">
  <img src="assets/play_video.png" width="400">
</a>

A mobile prediction game where two players commit to secret numbers, guess each other’s numbers, and settle outcomes with **Circom Groth16 proofs**, **Mopro** (device prover + Garaga calldata), and an on-chain **Starknet** contract—without revealing secrets beyond what the circuit allows.

**Notice:** Functional against Sepolia-style deployments; UI is still work in progress.

## Major technologies

- **Flutter / Dart** — mobile UI and Starknet client calls
- **Starknet.dart** (path: `packages/starknet.dart`) — accounts, RPC, AVNU paymaster
- **Mopro + Flutter Rust Bridge** (`mopro_flutter_bindings`) — Circom prove + Garaga calldata
- **Circom** (`circuit/guess.circom`) — Poseidon commitment + equality
- **Cairo / Scarb** (`contract/`) — ZKPes game + Groth16 verifier sources
- **AVNU** — sponsored Argent account deploy

## Repository structure

| Path | Role |
|------|------|
| `lib/` | Flutter app (screens, Starknet services, ZK helpers) |
| `integration_test/` | Full two-player gameplay test (needs device + native libs) |
| `mopro_flutter_bindings/` | FFI plugin wrapping mopro / FRB |
| `packages/starknet.dart/` | Vendored Starknet.dart packages |
| `contract/` | Cairo game + verifier |
| `circuit/` | Circom sources and mopro template snippets |
| `assets/` | zkey, verification key, images |
| `docs/` | Architecture, status, decisions for contributors/agents |

Agent-oriented instructions: [AGENTS.md](AGENTS.md). Deeper docs: [docs/architecture.md](docs/architecture.md), [docs/current-status.md](docs/current-status.md), [docs/decisions.md](docs/decisions.md).

## How to play

1. Create a free account (AVNU Paymaster + Starknet.dart Argent deploy).
2. Register a game slot on Starknet (`create_game`).
3. Set your secret number (private; only Poseidon commitment is published).
4. Invite a friend to install the app and join the same game id.
5. Guess your friend’s secret number (`write_intent`).
6. Friend checks the guess (device builds ZK proof + Garaga calldata → `verify_intent`).
7. Contract records win/loss; winner claims STRK reward (`claim_reward`).

If a player fails to send a required proof within **1000 blocks**, the opponent can claim via the timeout path.

## Prerequisites

- Flutter SDK compatible with `sdk: ^3.9.2` in `pubspec.yaml`
- Android emulator or device (for app run and integration test; native mopro libs)
- Rust toolchain (native plugin build via Cargokit)
- Sibling checkout of **`mopro-example-app3`** at `../../../mopro-example-app3` relative to `mopro_flutter_bindings/rust` (see that crate’s `Cargo.toml`)
- For contracts: Scarb / Starknet Foundry versions in `contract/.tool-versions`
- Configured `.env` (see `.env.example`)

## Setup

```bash
cp .env.example .env
# Edit .env with RPC, contract, STRK, AVNU, and (for tests) Argent PKs

flutter pub get
```

Ensure `mopro-example-app3` is available and contains Circom witness artifacts / zkey wiring expected by mopro (see historical notes under [MOPRO](#mopro) below).

## Run the app

```bash
flutter devices
flutter run -d <device_id>
```

After Rust/FFI changes, prefer a clean rebuild (`flutter clean` then `flutter run`) rather than hot restart.

## Development commands

```bash
flutter pub get
flutter analyze
flutter run -d <device_id>
```

## Tests

**Full gameplay (recommended):** requires emulator/device, funded accounts, RPC, and native mopro:

```bash
flutter test integration_test/full_gameplay_test.dart -d emulator-5554
```

Env keys required by the test are documented in `integration_test/full_gameplay_test.dart` and `.env.example` (`ACCOUNT1_SEPOLIA_ARGENTX_PK`, `ACCOUNT2_SEPOLIA_ARGENTX_PK`, etc.).

**Note:** `test/widget_test.dart` is still the default Flutter counter stub and does not reflect this app.

## Configuration

Copy `.env.example` to `.env`. Important variables:

- `STARKNET_NODE_URI`, `STARKNET_WSS` — RPC / websocket
- `CONTRACT_ADDRESS`, `STRK_TOKEN_ADDRESS` — game + fee token
- `AVNU_RPC` — paymaster
- `ACCOUNT1_SEPOLIA_ARGENTX_PK` / `ACCOUNT2_SEPOLIA_ARGENTX_PK` — integration test players

Never commit real private keys. `.env` is also listed as a Flutter asset in `pubspec.yaml`.

## Architecture diagram

![ESP Arch](assets/arch.png)

See also [docs/architecture.md](docs/architecture.md).

## TO DO

1. Improve UI
2. Add gasless transactions (free txs for early users)
3. Communicate apps through indexers

## To integrate Starknet.dart into zk_guess

```bash
mkdir packages
cd packages
git clone https://github.com/focustree/starknet.dart.git
cd starknet.dart
git submodule update --init --recursive

git fetch
git pull
git checkout main
cargo install --path .
```

(This repo already vendors `packages/starknet.dart`; use the above when re-cloning or updating from upstream.)

## ZK Circom

In WSL (historical recipe; adapt circuit name `guess` for this project):

```bash
git clone https://github.com/iden3/circom.git
cd circom
cargo build --release
cargo install --path circom
npm install -g snarkjs
git clone https://github.com/iden3/circomlib.git

cd circuit
# compile your circuit, e.g. guess.circom --r1cs --wasm --sym --c
# then snarkjs ptau / groth16 setup / zkey contribute / export verificationkey
# copy zkey (+ witness artifacts) into the mopro example test-vectors as required
```

## Garaga

Create verification contract material (versions and paths may need updating for current Garaga/Scarb):

```bash
cd garaga
source venv/bin/activate
garaga gen --vk verification_key.json --system groth16
scarb build
```

Deploy (example commands from prior local setups; URLs/class hashes are environment-specific):

```bash
scarb build
sncast --account player1 --accounts-file ../../.starknet_accounts/starknet_open_zeppelin_accounts.json declare-from --sierra-file target/dev/zkguess_integrationtest_Groth16VerifierBN254.test.contract_class.json --url http://localhost:9545/rpc/v0_10 --l1-gas 0 --l1-gas-price 200512996931799 --l2-gas 4200000000 --l2-gas-price 45704468436 --l1-data-gas 288 --l1-data-gas-price 836146516447
sncast --account player1 --accounts-file ../../.starknet_accounts/starknet_open_zeppelin_accounts.json deploy --class-hash 0x1287bd4b5d1bac1548d7c3185d2cf7824749d5a6bb11ac6b5da41625c786d3 --url http://localhost:9545/rpc/v0_10

scarb build
sncast --account player1 --accounts-file ../../.starknet_accounts/starknet_open_zeppelin_accounts.json declare-from --sierra-file target/dev/guess_ZKPes.contract_class.json --url http://localhost:9545/rpc/v0_10
sncast --account player1 --accounts-file ../../.starknet_accounts/starknet_open_zeppelin_accounts.json deploy --class-hash 0x3f03ed868b35d802b03f3069115daa0ec33d31eb82d784a7781449b2d3d5bfc --url http://localhost:9545/rpc/v0_10
```

## MOPRO

Install / build (historical host paths; adjust `ANDROID_HOME` / NDK):

```bash
cargo install mopro-cli
mopro init
export ANDROID_HOME="/path/to/Android/Sdk/"
export NDK_PATH=$ANDROID_HOME/ndk/<version>
mopro build
```

Integrate with this app’s bindings:

```bash
# Create/configure mopro-example-app3 (sibling of StudioProjects):
mopro init
# edit Cargo.toml for garaga / guess circuit as needed
# edit src/lib.rs for the guess circuit
mopro build

# In zk_guess:
# point mopro_flutter_bindings/rust/Cargo.toml at that example path
# copy guess.wasm and guess_0001.zkey into mopro-example-app3 test-vectors as required
```

Current app Rust dependency path: `mopro_flutter_bindings/rust/Cargo.toml` → `../../../mopro-example-app3`.
