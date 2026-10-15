import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:mopro_flutter_bindings/src/rust/third_party/mopro_example_app3.dart';
import 'package:path_provider/path_provider.dart';
import 'package:poseidon/poseidon.dart';
import 'package:starknet/starknet.dart';

/// Poseidon commitment: salt + hash for a secret number `x`.
class Commitment {
  final BigInt salt;
  final BigInt hash;

  const Commitment({required this.salt, required this.hash});
}

/// Computes a Poseidon commitment for [secret], resampling salt until the
/// hash fits in a Starknet felt (same loop as the game UI).
Commitment computeCommitment(BigInt secret) {
  final feltPrime =
      BigInt.two.pow(251) + BigInt.from(17) * BigInt.two.pow(192) + BigInt.one;

  BigInt salt;
  BigInt hash;
  do {
    salt = BigInt.from(Random().nextInt(4294967296));
    hash = poseidon2([secret, salt]);
  } while (hash >= feltPrime);

  return Commitment(salt: salt, hash: hash);
}

/// Copies a Flutter asset to a temp file so Rust can open it by path.
Future<String> copyAssetToTemp(String assetPath) async {
  final fileName = assetPath.split('/').last;
  final tempDir = await getTemporaryDirectory();
  final outFile = File('${tempDir.path}/$fileName');
  if (!await outFile.exists()) {
    final data = await rootBundle.load(assetPath);
    await outFile.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }
  return outFile.path;
}

/// Generates a Circom proof and Garaga calldata for verify_intent.
Future<List<Felt>> proveAndBuildGaragaCalldata({
  required BigInt x,
  required BigInt salt,
  required BigInt h,
  required BigInt y,
}) async {
  final inputs = '{"x":["$x"],"salt":["$salt"],"h":["$h"],"y":["$y"]}';
  final zkeyPath = await copyAssetToTemp('assets/guess_0001.zkey');
  final proofResult = await generateCircomProof(
    zkeyPath: zkeyPath,
    circuitInputs: inputs,
    proofLib: ProofLib.arkworks,
  );

  final vkJson = await rootBundle.loadString(
    'assets/garaga_verification_key.json',
  );
  // Print proofResult as JSON for copy/paste into garaga tooling.
  // CircomProofResult has no toJson, so build an encodable map.
  print(
    jsonEncode({
      'proof': {
        'a': {
          'x': proofResult.proof.a.x,
          'y': proofResult.proof.a.y,
          'z': proofResult.proof.a.z,
        },
        'b': {
          'x': proofResult.proof.b.x,
          'y': proofResult.proof.b.y,
          'z': proofResult.proof.b.z,
        },
        'c': {
          'x': proofResult.proof.c.x,
          'y': proofResult.proof.c.y,
          'z': proofResult.proof.c.z,
        },
        'protocol': proofResult.proof.protocol,
        'curve': proofResult.proof.curve,
      },
      'inputs': proofResult.inputs,
    }),
  );
  final calldata = (await generateCircomGroth16GaragaCalldata(
    proofResult: proofResult,
    verificationKeyJson: vkJson,
  )).map((felt) => Felt(BigInt.parse(felt))).toList();
  return calldata;
}
