import 'package:avnu_provider/avnu_provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';
import 'package:zk_guess/services.dart';

/// Argent X account class hash used by this app (no guardian).
final Felt _argentClassHash = Felt.fromHexString(
  '0x036078334509b514626504edc9fb252328d1a240e4e948bef8d0c08dff45927f',
);

/// Same API key the app uses for sponsored deploy (override with AVNU_API_KEY).
const String _defaultAvnuApiKey = '04a163bf-65e0-4ff7-870d-64379f3d6c92';

const String account1PkEnvKey = 'ACCOUNT1_SEPOLIA_ARGENTX_PK';
const String account2PkEnvKey = 'ACCOUNT2_SEPOLIA_ARGENTX_PK';

/// Derives the Argent account address from an owner private key
/// (class hash + constructor calldata + salt = public key).
Felt deriveArgentAddressFromPrivateKey(Felt privateKey) {
  final ownerSigner = StarkSigner(privateKey: privateKey);
  final accountSigner = ArgentXGuardianAccountSigner(
    ownerSigner: ownerSigner,
    guardianSigner: null,
  );
  return Contract.computeAddress(
    classHash: _argentClassHash,
    calldata: accountSigner.constructorCalldata,
    salt: ownerSigner.publicKey,
  );
}

AvnuPaymasterProvider _avnuPaymaster() {
  final avnuRpc = dotenv.env['AVNU_RPC'];
  if (avnuRpc == null || avnuRpc.isEmpty) {
    throw StateError('AVNU_RPC is required to deploy missing test accounts');
  }
  final apiKey = dotenv.env['AVNU_API_KEY'];
  return AvnuPaymasterProviderImpl(
    nodeUri: Uri.parse(avnuRpc.replaceAll('"', '')),
    apiKey: (apiKey == null || apiKey.isEmpty) ? _defaultAvnuApiKey : apiKey,
  );
}

Future<bool> _isDeployed(Felt address) async {
  final classAt = await provider.getClassHashAt(
    contractAddress: address,
    blockId: BlockId.latest,
  );
  return classAt.when(result: (_) => true, error: (_) => false);
}

/// Sponsored Argent deploy via AVNU (same flow as the app).
Future<void> _deployViaAvnu({
  required Felt address,
  required StarkSigner ownerSigner,
  required ArgentXGuardianAccountSigner accountSigner,
}) async {
  final deployment = AccountDeploymentData(
    address: address.toHexString(),
    classHash: _argentClassHash.toHexString(),
    salt: ownerSigner.publicKey.toHexString(),
    calldata: accountSigner.constructorCalldata
        .map((e) => e.toHexString())
        .toList(),
  );

  final paymaster = _avnuPaymaster();
  const parameters = UserParameters(feeMode: FeeMode.sponsored());
  final build = await paymaster.buildTransaction(
    UserTransaction.deploy(deployment: deployment),
    parameters,
  );
  final result = await paymaster.executeTransaction(
    ExecutableUserTransaction.deploy(deployment: deployment),
    build.parameters,
  );

  final accepted = await waitForAcceptance(
    transactionHash: result.transactionHash,
    provider: provider,
  );
  if (!accepted) {
    throw StateError(
      'AVNU deploy was not accepted: ${result.transactionHash} '
      '(address ${address.toHexString()})',
    );
  }
}

/// Loads an Argent account from a Sepolia PK env var.
/// If the derived address is not deployed, deploys it via AVNU paymaster
/// (same as the app). Does not redeploy existing accounts.
Future<Account> accountFromSepoliaArgentPk(String envKey) async {
  final privateKeyHex = dotenv.env[envKey];
  if (privateKeyHex == null || privateKeyHex.isEmpty) {
    throw StateError('Missing $envKey in .env');
  }

  final privateKey = Felt.fromHexString(privateKeyHex);
  final ownerSigner = StarkSigner(privateKey: privateKey);
  final accountSigner = ArgentXGuardianAccountSigner(
    ownerSigner: ownerSigner,
    guardianSigner: null,
  );
  final address = deriveArgentAddressFromPrivateKey(privateKey);

  if (!await _isDeployed(address)) {
    // ignore: avoid_print
    print(
      '$envKey account ${address.toHexString()} not deployed; '
      'deploying via AVNU paymaster...',
    );
    await _deployViaAvnu(
      address: address,
      ownerSigner: ownerSigner,
      accountSigner: accountSigner,
    );
    if (!await _isDeployed(address)) {
      throw StateError(
        'AVNU deploy finished but ${address.toHexString()} still has no class',
      );
    }
  }

  return Account(
    provider: provider,
    signer: accountSigner,
    accountAddress: address,
    chainId: StarknetChainId.testNet,
  );
}

/// Ensures RPC + contract + Argent PK (+ AVNU for deploy-if-missing) env vars.
void requireGameplayEnv() {
  final required = [
    'STARKNET_NODE_URI',
    'CONTRACT_ADDRESS',
    'STRK_TOKEN_ADDRESS',
    'AVNU_RPC',
    account1PkEnvKey,
    account2PkEnvKey,
  ];
  final missing = required
      .where((k) {
        final v = dotenv.env[k];
        return v == null || v.isEmpty || v == '""';
      })
      .toList();
  if (missing.isNotEmpty) {
    throw StateError(
      'Missing required .env keys for gameplay test: ${missing.join(', ')}',
    );
  }
}
