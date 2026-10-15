/// Full P1/P2 gameplay integration test (headless; exercises ZK + chain).
///
/// Prerequisites:
/// - `.env` with STARKNET_NODE_URI, CONTRACT_ADDRESS, STRK_TOKEN_ADDRESS,
///   AVNU_RPC, ACCOUNT1_SEPOLIA_ARGENTX_PK, ACCOUNT2_SEPOLIA_ARGENTX_PK
/// - PKs for Argent (no guardian, class hash 0x03607833…927f). If not
///   deployed yet, the test deploys them via AVNU paymaster (same as the app).
///   Accounts still need STRK for gameplay fees after deploy.
/// - assets/guess_0001.zkey and assets/garaga_verification_key.json present
/// - Android emulator/device (native mopro FFI required)
///
/// Run:
///   flutter test integration_test/full_gameplay_test.dart -d `<android_device>`
///
/// Flow: P1 creates → P2 joins → P1 wrong guess → P2 verifies (→ p2_turn) →
/// P2 correct guess → P1 verifies → P2 claims → status finished.
library;

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mopro_flutter_bindings/mopro_flutter_bindings.dart';
import 'package:starknet/starknet.dart';
import 'package:zk_guess/gameplay_helpers.dart';
import 'package:zk_guess/services.dart';

import 'test_accounts.dart';

void _log(String message) {
  // ignore: avoid_print
  print('[gameplay_test] $message');
}

const int _maxProveVerifyAttempts = 5;

/// Regenerates the ZK proof and invokes verify_intent, up to 5 attempts.
Future<void> _proveAndVerifyWithRetry({
  required String stepLabel,
  required Uint256 gameId,
  required Account account,
  required BigInt x,
  required BigInt salt,
  required BigInt h,
  required BigInt y,
}) async {
  Object? lastError;
  for (var attempt = 1; attempt <= _maxProveVerifyAttempts; attempt++) {
    try {
      _log(
        '$stepLabel: attempt $attempt/$_maxProveVerifyAttempts — '
        'generate proof...',
      );
      final proof = await proveAndBuildGaragaCalldata(
        x: x,
        salt: salt,
        h: h,
        y: y,
      );
      _log(
        '$stepLabel: proof calldata length=${proof.length}; '
        'invoke verify_intent',
      );
      await invokeVerifyIntent(gameId, proof, account: account);
      _log('$stepLabel: verify_intent succeeded on attempt $attempt');
      return;
    } catch (e) {
      lastError = e;
      _log('$stepLabel: attempt $attempt/$_maxProveVerifyAttempts failed: $e');
      if (attempt == _maxProveVerifyAttempts) {
        break;
      }
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
  }
  throw StateError(
    '$stepLabel: prove+verify failed after $_maxProveVerifyAttempts '
    'attempts. Last error: $lastError',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'full gameplay: p2 wins and claims reward',
    (tester) async {
      _log('START: loading .env / RustLib / accounts');
      await dotenv.load(fileName: '.env');
      requireGameplayEnv();
      await RustLib.init();
      _log('RustLib initialized');

      _log('Loading P1 from $account1PkEnvKey...');
      final p1 = await accountFromSepoliaArgentPk(account1PkEnvKey);
      _log('P1 ready: ${p1.accountAddress.toHexString()}');

      _log('Loading P2 from $account2PkEnvKey...');
      final p2 = await accountFromSepoliaArgentPk(account2PkEnvKey);
      _log('P2 ready: ${p2.accountAddress.toHexString()}');

      final p1Secret = BigInt.from(42);
      final p2Secret = BigInt.from(7);
      final wrongGuess = BigInt.from(99);

      final gameId = Uint256.fromBigInt(
        BigInt.from(DateTime.now().millisecondsSinceEpoch),
      );
      final reward = Uint256.fromBigInt(BigInt.one);
      _log('gameId=${gameId.toBigInt()} reward=${reward.toBigInt()} FRI');

      // 1) P1 create game
      _log('STEP 1: P1 compute commitment + approve + create_game');
      final p1Commit = computeCommitment(p1Secret);
      _log('STEP 1: P1 commitment hash=${p1Commit.hash}');
      await approveEntryFee(reward, account: p1);
      _log('STEP 1: P1 entry fee approved');
      await invokeCreateGame(
        gameId,
        Uint256.fromBigInt(p1Commit.hash),
        reward,
        account: p1,
      );
      var status = (await getGameProperties(gameId, account: p1)).status;
      _log('STEP 1 DONE: status=$status (expected created)');
      expect(status, 'created');

      // 2) P2 join game
      _log('STEP 2: P2 compute commitment + approve + join_game');
      final p2Commit = computeCommitment(p2Secret);
      _log('STEP 2: P2 commitment hash=${p2Commit.hash}');
      await approveEntryFee(reward, account: p2);
      _log('STEP 2: P2 entry fee approved');
      await invokeJoinGame(
        gameId,
        Uint256.fromBigInt(p2Commit.hash),
        account: p2,
      );
      status = (await getGameProperties(gameId, account: p2)).status;
      _log('STEP 2 DONE: status=$status (expected p1_turn)');
      expect(status, 'p1_turn');

      // 3) P1 guesses wrongly
      _log('STEP 3: P1 write_intent wrongGuess=$wrongGuess');
      await invokeWriteIntent(
        gameId,
        Uint256.fromBigInt(wrongGuess),
        account: p1,
      );
      status = (await getGameProperties(gameId, account: p1)).status;
      _log('STEP 3 DONE: status=$status (expected p2_verify)');
      expect(status, 'p2_verify');

      // 4) P2 validates wrong guess (equal=0) → p2_turn (opponent validates, then guesses)
      _log('STEP 4: P2 generate ZK proof (wrong guess, equal=0)...');
      await _proveAndVerifyWithRetry(
        stepLabel: 'STEP 4',
        gameId: gameId,
        account: p2,
        x: p2Secret,
        salt: p2Commit.salt,
        h: p2Commit.hash,
        y: wrongGuess,
      );
      status = (await getGameProperties(gameId, account: p2)).status;
      _log('STEP 4 DONE: status=$status (expected p2_turn)');
      expect(status, 'p2_turn');

      // 5) P2 guesses P1 correctly
      _log('STEP 5: P2 write_intent correctGuess=$p1Secret');
      await invokeWriteIntent(
        gameId,
        Uint256.fromBigInt(p1Secret),
        account: p2,
      );
      status = (await getGameProperties(gameId, account: p2)).status;
      _log('STEP 5 DONE: status=$status (expected p1_verify)');
      expect(status, 'p1_verify');

      // 6) P1 validates correct guess (equal=1) → win_p2
      _log('STEP 6: P1 generate ZK proof (correct guess, equal=1)...');
      await _proveAndVerifyWithRetry(
        stepLabel: 'STEP 6',
        gameId: gameId,
        account: p1,
        x: p1Secret,
        salt: p1Commit.salt,
        h: p1Commit.hash,
        y: p1Secret,
      );
      status = (await getGameProperties(gameId, account: p1)).status;
      _log('STEP 6 DONE: status=$status (expected win_p2)');
      expect(status, 'win_p2');

      // 7) P2 claims reward
      _log('STEP 7: P2 claim_reward');
      await invokeClaimReward(gameId, account: p2);
      status = (await getGameProperties(gameId, account: p2)).status;
      _log('STEP 7 DONE: status=$status (expected finished)');
      expect(status, 'finished');

      _log('SUCCESS: full gameplay finished');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
