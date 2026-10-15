// ignore_for_file: prefer_const_declarations, avoid_print

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

final _storage = const FlutterSecureStorage();

Future<String> getSecretAccountAddress() async {
  final accountData = await _storage.read(key: 'selected_account');
  if (accountData == null) return '';
  final data = jsonDecode(accountData);
  return data['address'] ?? '';
}

Future<String> getSecretAccountPrivateKey() async {
  final accountData = await _storage.read(key: 'selected_account');
  if (accountData == null) return '';
  final data = jsonDecode(accountData);
  return data['privateKey'] ?? '';
}

Future<String?> getAccountNickname(String address) async {
  try {
    // Get all stored keys
    final allKeys = await _storage.readAll();

    // Search for the account with matching address
    for (var key in allKeys.keys) {
      if (key.startsWith('account_')) {
        final accountData = jsonDecode(allKeys[key]!);
        if (accountData['address'] == address) {
          return accountData['nickname'];
        }
      }
    }

    // Check if it's the hardcoded account 1
    final env = dotenv.env;
    if (env['ACCOUNT1_ADDRESS'] == address) {
      return env['ACCOUNT1_NICKNAME'] ?? 'Admin';
    }

    return null;
  } catch (e) {
    return null;
  }
}

final secretAccountAddress = getSecretAccountAddress();
final secretAccountPrivateKey = getSecretAccountPrivateKey();

final provider = JsonRpcProvider(
  nodeUri: Uri.parse(dotenv.env['STARKNET_NODE_URI'] ?? ''),
);
final contractAddress = dotenv.env['CONTRACT_ADDRESS'] ?? '';

// starknet.dart truncates fractional feeMultiplier via Felt.fromDouble (1.2 → 1).
const _feeBuffer = 1.5;

class _BufferedFee {
  final Felt l1GasConsumed;
  final Felt l1GasPrice;
  final Felt l1DataGasConsumed;
  final Felt l1DataGasPrice;
  final Felt l2GasConsumed;
  final Felt l2GasPrice;

  _BufferedFee(FeeEstimations maxFee)
      : l1GasConsumed = maxFee.l1GasConsumed.multiplyByDouble(_feeBuffer),
        l1GasPrice = maxFee.l1GasPrice.multiplyByDouble(_feeBuffer),
        l1DataGasConsumed =
            maxFee.l1DataGasConsumed.multiplyByDouble(_feeBuffer),
        l1DataGasPrice = maxFee.l1DataGasPrice.multiplyByDouble(_feeBuffer),
        l2GasConsumed = maxFee.l2GasConsumed.multiplyByDouble(_feeBuffer),
        l2GasPrice = maxFee.l2GasPrice.multiplyByDouble(_feeBuffer);
}

Future<void> _waitForSuccessfulTx(String txHash) async {
  final accepted = await waitForAcceptance(
    transactionHash: txHash,
    provider: provider,
  );
  if (!accepted) {
    throw Exception('Transaction reverted or was not accepted: $txHash');
  }
}

Future<Account> getSignerAccount() async {
  final address = await getSecretAccountAddress();
  final privateKey = await getSecretAccountPrivateKey();
  final ownerSigner = StarkSigner(privateKey: Felt.fromHexString(privateKey));
  final accountSigner = ArgentXGuardianAccountSigner(
    ownerSigner: ownerSigner,
    guardianSigner: null,
  );
  return Account(
    provider: provider,
    signer: accountSigner,
    accountAddress: Felt.fromHexString(address),
    chainId: StarknetChainId.testNet,
  );
}

Future<Account> _resolveAccount(Account? account) async =>
    account ?? await getSignerAccount();

// invoke zk_guess contract to register the commitment as
// specified in zk_guess.cairo
// invoke the contract with the hash as the calldata
Future<String> invokeCreateGame(
  Uint256 gameId,
  Uint256 hash,
  Uint256 reward, {
  Account? account,
}) async {
  final signer = await _resolveAccount(account);
  final maxFee = await signer.getEstimateMaxFeeForInvokeTx(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("create_game"),
        calldata: [
          gameId.low,
          gameId.high,
          hash.low,
          hash.high,
          reward.low,
          reward.high,
        ],
      ),
    ],
  );
  final fee = _BufferedFee(maxFee);
  final response = await signer.execute(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("create_game"),
        calldata: [
          gameId.low,
          gameId.high,
          hash.low,
          hash.high,
          reward.low,
          reward.high,
        ],
      ),
    ],
    incrementNonceIfNonceRelatedError: true,
    maxAttempts: 5,
    l1GasConsumed: fee.l1GasConsumed,
    l1GasPrice: fee.l1GasPrice,
    l2GasConsumed: fee.l2GasConsumed,
    l2GasPrice: fee.l2GasPrice,
    l1DataGasConsumed: fee.l1DataGasConsumed,
    l1DataGasPrice: fee.l1DataGasPrice,
  );
  final txHash = response.when(
    result: (result) => result.transaction_hash,
    error: (err) => throw Exception("Failed to invoke register commitment"),
  );
  print('Invoking register commitment TX : $txHash');
  await _waitForSuccessfulTx(txHash);
  return txHash;
}

// function to invoke verify_intent defined as:
// fn verify_intent(ref self: TContractState, game_id: u256, full_proof_with_hints: Span<felt252>);

Future<String> invokeVerifyIntent(
  Uint256 gameId,
  List<Felt> fullProofWithHints, {
  Account? account,
}) async {
  final signer = await _resolveAccount(account);
  final calldata = [
    gameId.low,
    gameId.high,
    ...fullProofWithHints.map((felt) => felt),
  ];
  print("Calldata: $calldata");
  final maxFee = await signer.getEstimateMaxFeeForInvokeTx(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("verify_intent"),
        calldata: calldata,
      ),
    ],
  );
  final fee = _BufferedFee(maxFee);
  final response = await signer.execute(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("verify_intent"),
        calldata: [
          gameId.low,
          gameId.high,
          ...fullProofWithHints.map((felt) => felt),
        ],
      ),
    ],
    incrementNonceIfNonceRelatedError: true,
    maxAttempts: 5,
    l1GasConsumed: fee.l1GasConsumed,
    l1GasPrice: fee.l1GasPrice,
    l2GasConsumed: fee.l2GasConsumed,
    l2GasPrice: fee.l2GasPrice,
    l1DataGasConsumed: fee.l1DataGasConsumed,
    l1DataGasPrice: fee.l1DataGasPrice,
  );
  final txHash = response.when(
    result: (result) => result.transaction_hash,
    error: (err) => throw Exception("Failed to invoke verify intent"),
  );
  print('Invoking verify intent TX : $txHash');
  await _waitForSuccessfulTx(txHash);
  return txHash;
}

Future<String> approveEntryFee(Uint256 entryFee, {Account? account}) async {
  final signer = await _resolveAccount(account);
  final strkTokenAddress = dotenv.env['STRK_TOKEN_ADDRESS'] ?? '';
  final calldata = [
    Felt.fromHexString(contractAddress), // spender (contract address)
    entryFee.low, // amount low
    entryFee.high, // amount high
  ];
  // first estimate the max fee
  final maxFee = await signer.getEstimateMaxFeeForInvokeTx(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(strkTokenAddress),
        entryPointSelector: getSelectorByName("approve"),
        calldata: calldata,
      ),
    ],
  );
  final fee = _BufferedFee(maxFee);
  final response = await signer.execute(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(strkTokenAddress),
        entryPointSelector: getSelectorByName("approve"),
        calldata: calldata,
      ),
    ],
    incrementNonceIfNonceRelatedError: true,
    maxAttempts: 5,
    l1GasConsumed: fee.l1GasConsumed,
    l1GasPrice: fee.l1GasPrice,
    l2GasConsumed: fee.l2GasConsumed,
    l2GasPrice: fee.l2GasPrice,
    l1DataGasConsumed: fee.l1DataGasConsumed,
    l1DataGasPrice: fee.l1DataGasPrice,
  );

  final txHash = response.when(
    result: (result) => result.transaction_hash,
    error: (err) => throw Exception("Failed to approve entry fee"),
  );

  await _waitForSuccessfulTx(txHash);

  print('Approving entry fee TX: $txHash');
  return txHash;
}

Future<String> invokeWriteIntent(
  Uint256 gameId,
  Uint256 intent, {
  Account? account,
}) async {
  final signer = await _resolveAccount(account);
  final maxFee = await signer.getEstimateMaxFeeForInvokeTx(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("write_intent"),
        calldata: [gameId.low, gameId.high, intent.low, intent.high],
      ),
    ],
  );
  final fee = _BufferedFee(maxFee);
  final response = await signer.execute(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("write_intent"),
        calldata: [gameId.low, gameId.high, intent.low, intent.high],
      ),
    ],
    incrementNonceIfNonceRelatedError: true,
    maxAttempts: 5,
    l1GasConsumed: fee.l1GasConsumed,
    l1GasPrice: fee.l1GasPrice,
    l2GasConsumed: fee.l2GasConsumed,
    l2GasPrice: fee.l2GasPrice,
    l1DataGasConsumed: fee.l1DataGasConsumed,
    l1DataGasPrice: fee.l1DataGasPrice,
  );
  final txHash = response.when(
    result: (result) => result.transaction_hash,
    error: (err) => throw Exception("Failed to invoke write intent"),
  );
  print('Invoking write intent TX : $txHash');
  await _waitForSuccessfulTx(txHash);
  return txHash;
}

Future<String> invokeJoinGame(
  Uint256 gameId,
  Uint256 commitment, {
  Account? account,
}) async {
  final signer = await _resolveAccount(account);
  final maxFee = await signer.getEstimateMaxFeeForInvokeTx(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("join_game"),
        calldata: [gameId.low, gameId.high, commitment.low, commitment.high],
      ),
    ],
  );
  final fee = _BufferedFee(maxFee);
  final response = await signer.execute(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("join_game"),
        calldata: [gameId.low, gameId.high, commitment.low, commitment.high],
      ),
    ],
    incrementNonceIfNonceRelatedError: true,
    maxAttempts: 5,
    l1GasConsumed: fee.l1GasConsumed,
    l1GasPrice: fee.l1GasPrice,
    l2GasConsumed: fee.l2GasConsumed,
    l2GasPrice: fee.l2GasPrice,
    l1DataGasConsumed: fee.l1DataGasConsumed,
    l1DataGasPrice: fee.l1DataGasPrice,
  );
  final txHash = response.when(
    result: (result) => result.transaction_hash,
    error: (err) => throw Exception("Failed to invoke join game"),
  );
  print('Invoking join game TX : $txHash');
  await _waitForSuccessfulTx(txHash);
  return txHash;
}

Future<String> invokeClaimReward(Uint256 gameId, {Account? account}) async {
  final signer = await _resolveAccount(account);
  final maxFee = await signer.getEstimateMaxFeeForInvokeTx(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("claim_reward"),
        calldata: [gameId.low, gameId.high],
      ),
    ],
  );
  final fee = _BufferedFee(maxFee);
  final response = await signer.execute(
    functionCalls: [
      FunctionCall(
        contractAddress: Felt.fromHexString(contractAddress),
        entryPointSelector: getSelectorByName("claim_reward"),
        calldata: [gameId.low, gameId.high],
      ),
    ],
    incrementNonceIfNonceRelatedError: true,
    maxAttempts: 5,
    l1GasConsumed: fee.l1GasConsumed,
    l1GasPrice: fee.l1GasPrice,
    l2GasConsumed: fee.l2GasConsumed,
    l2GasPrice: fee.l2GasPrice,
    l1DataGasConsumed: fee.l1DataGasConsumed,
    l1DataGasPrice: fee.l1DataGasPrice,
  );
  final txHash = response.when(
    result: (result) => result.transaction_hash,
    error: (err) => throw Exception("Failed to invoke claim reward"),
  );
  print('Invoking claim reward TX : $txHash');
  await _waitForSuccessfulTx(txHash);
  return txHash;
}

Future<Felt> getElapsedBlocks(Uint256 gameId, {Account? account}) async {
  final signer = await _resolveAccount(account);
  // Get current block number and the block number of the last intent
  // then return the difference
  final BlockNumber currentBlockNumber = await provider.blockNumber();
  final current = currentBlockNumber.when(
    result: (n) => BigInt.from(n),
    error: (e) => throw Exception('blockNumber error: ${e.message}'),
  );
  // Get the block number of the last intent
  // using get_game_properties from the contract
  final contract = Contract(
    account: signer,
    address: Felt.fromHexString(contractAddress),
  );
  final List<Felt> gameProperties = await contract.call("get_game_properties", [
    gameId.low,
    gameId.high,
  ]);
  final BigInt lastIntentBlockNumber = gameProperties[10].toBigInt();
  return Felt(current - lastIntentBlockNumber);
}

// Game struct matching the Cairo game_struct
class GameStruct {
  final Felt player1;
  final Felt player2;
  final Uint256 commitment1;
  final Uint256 commitment2;
  final Uint256 reward;
  final Uint256 lastIntent;
  final BigInt lastIntentBlockNumber;
  final String status;

  GameStruct({
    required this.player1,
    required this.player2,
    required this.commitment1,
    required this.commitment2,
    required this.reward,
    required this.lastIntent,
    required this.lastIntentBlockNumber,
    required this.status,
  });
}

// Get game properties and return GameStruct
Future<GameStruct> getGameProperties(Uint256 gameId, {Account? account}) async {
  final signer = await _resolveAccount(account);
  final contract = Contract(
    account: signer,
    address: Felt.fromHexString(contractAddress),
  );
  final List<Felt> gameProperties = await contract.call("get_game_properties", [
    gameId.low,
    gameId.high,
  ]);

  // Parse the response according to Cairo struct order:
  // (ContractAddress, ContractAddress, u256, u256, u256, u256, u64, felt252)
  // Which translates to: [player1, player2, commitment1.low, commitment1.high,
  //                       commitment2.low, commitment2.high, reward.low, reward.high,
  //                       last_intent.low, last_intent.high, last_intent_blocknumber, status]
  return GameStruct(
    player1: gameProperties[0],
    player2: gameProperties[1],
    commitment1: Uint256(low: gameProperties[2], high: gameProperties[3]),
    commitment2: Uint256(low: gameProperties[4], high: gameProperties[5]),
    reward: Uint256(low: gameProperties[6], high: gameProperties[7]),
    lastIntent: Uint256(low: gameProperties[8], high: gameProperties[9]),
    lastIntentBlockNumber: gameProperties[10].toBigInt(),
    status: _feltToAscii(gameProperties[11]),
  );
}

// Decode a Starknet felt (BigInt) to its ASCII string representation.
// Removes leading zeros and stops at null bytes.
String _feltToAscii(Felt felt) {
  final hex = felt.toHexString().replaceFirst('0x', '');
  if (hex.isEmpty) return '';
  final buffer = StringBuffer();
  for (int i = 0; i + 1 < hex.length; i += 2) {
    final byte = int.parse(hex.substring(i, i + 2), radix: 16);
    if (byte == 0) break; // stop at null terminator
    buffer.writeCharCode(byte);
  }
  return buffer.toString();
}
