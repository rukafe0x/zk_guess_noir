# Decisions

Architectural and implementation choices evident from this repository. Rationales only where supported by code or history.

### Flutter client with path-vendored Starknet.dart

**Decision:** App depends on `packages/starknet.dart` via `path:` (and `dependency_overrides`), not a pub.dev version pin alone.

**Rationale:** Commit history references upgrading Starknet Dart / RPC versions in-tree; monorepo packages (`starknet`, `starknet_provider`, `avnu_provider`) are used directly.

**Implications:** Starknet client changes require coordinating the vendored tree; agents should treat it as part of the workspace.

**Status:** Accepted

### Mopro + Flutter Rust Bridge for proving and Garaga calldata

**Decision:** Circom prove and Starknet Garaga calldata generation run in native code exposed through `mopro_flutter_bindings` (FRB), depending on external `mopro-example-app3`.

**Rationale:** Recent commits describe moving from a local `garaga_rs` FRB bridge to mopro’s Garaga calldata feature; app imports `mopro_example_app3` generated Dart API.

**Implications:** Device/native rebuild required for ZK; Dart VM tests cannot exercise prove; sibling `mopro-example-app3` path must exist and stay hash-synced with generated Dart.

**Status:** Accepted

### On-chain game state and rewards in Cairo ZKPes

**Decision:** Game lifecycle, commitments, intents, proof verification dispatch, and STRK reward transfer live in `contract/src/zk_pes.cairo`, with Groth16 verification delegated to a verifier contract.

**Rationale:** Not documented beyond contract comments and app call sites mirroring entrypoints.

**Implications:** Status transitions and timeout (1000 blocks) are contract-defined; Flutter must follow them (e.g. wrong guess after `p2_verify` → `p2_turn`).

**Status:** Accepted

### Poseidon commitments off-chain; Circom checks hash and equality

**Decision:** App commits with Dart `poseidon` package; circuit re-checks Poseidon(x,salt)=h and x=y.

**Rationale:** Matches `circuit/guess.circom` and `gameplay_helpers.computeCommitment`.

**Implications:** Commitment algorithm must stay consistent between Flutter and circuit; salt resampling until hash fits felt prime is required.

**Status:** Accepted

### Optional `Account` parameter on service invokes

**Decision:** `lib/services.dart` accepts optional `Account? account`, defaulting to secure-storage signer.

**Rationale:** Enables multi-player integration tests without UI account switching (introduced with gameplay integration test commit).

**Implications:** Production UI unchanged; tests must pass the correct account per step.

**Status:** Accepted

### AVNU sponsored Argent deploy for onboarding (and test deploy-if-missing)

**Decision:** New accounts use AVNU paymaster `deploy` with Argent class hash and no guardian; integration test derives address from PK and deploys the same way if undeployed.

**Rationale:** Implemented in `account_selection_screen.dart` and `integration_test/test_accounts.dart`; README describes free onboarding via AVNU.

**Implications:** Requires `AVNU_RPC`; gameplay still needs STRK after deploy; class hash / constructor must match derivation.

**Status:** Accepted

### `.env` loaded via flutter_dotenv and listed as a Flutter asset

**Decision:** Configuration and secrets are read from `.env` bundled as an asset.

**Rationale:** `main.dart` calls `dotenv.load(fileName: ".env")`; `pubspec.yaml` assets include `.env`.

**Implications:** Risk of shipping secrets in builds; agents must use placeholders and never commit real keys. Prefer `.env.example` for documentation.

**Status:** Accepted

### Integration tests target a real device/emulator

**Decision:** Full gameplay coverage lives under `integration_test/` with `IntegrationTestWidgetsFlutterBinding` and native `RustLib.init()`.

**Rationale:** ZK FFI cannot load in Dart VM; README documents `flutter test ... -d emulator-5554`.

**Implications:** CI without devices cannot run this test as-is; no alternative headless prover CLI is present in-repo.

**Status:** Accepted
