import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mopro_flutter_bindings/src/rust/third_party/mopro_example_app3.dart';
import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';

import 'gameplay_helpers.dart';
import 'services.dart';

class GameScreen extends StatefulWidget {
  final String accountAddress;
  final String accountNickname;
  final String? initialGameId;
  const GameScreen({
    super.key,
    required this.accountAddress,
    required this.accountNickname,
    this.initialGameId,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  CircomProofResult? _circomProofResult;
  bool? _circomValid;
  bool isProving = false;
  Exception? _error;
  late TabController _tabController;
  final _storage = const FlutterSecureStorage();

  // WebSocket connection and game state
  StarknetWebSocketChannel? _wsChannel;
  Map<String, dynamic>? gameState;
  bool _isConnected = false;
  String? _eventSubscriptionId;

  // Elapsed blocks polling
  Timer? _elapsedTimer;
  String? _elapsedBlocks;
  String? _latestStatus;
  String? _myRole;

  // Controllers to handle user input
  final TextEditingController _controllerGameId =
      TextEditingController(); // Game ID
  final TextEditingController _controllerX =
      TextEditingController(); // Private: secret number
  final TextEditingController _controllerY =
      TextEditingController(); // Public: guess
  final TextEditingController _controllerMyGuess =
      TextEditingController(); // My guess of opponent's number
  final TextEditingController _controllerBetAmount =
      TextEditingController(); // Bet amount

  @override
  void initState() {
    super.initState();
    if (widget.initialGameId == '-1') {
      // Pre-calculate Game ID with random value
      _controllerGameId.text = Random().nextInt(4294967296).toString();
      _myRole = 'Player 1';
    } else {
      final gameid = widget.initialGameId.toString();
      _controllerGameId.text = gameid;
      _myRole = 'Player 2';
    }
    _tabController = TabController(length: 1, vsync: this);

    // Initialize bet amount to 1
    _controllerBetAmount.text = '1';

    // Only load x from storage if initialGameId is not -1
    if ((_latestStatus != 'created') && (_latestStatus != null)) {
      _storage.read(key: 'x_${widget.accountAddress}').then((value) {
        if (value != null) {
          _controllerX.text = value;
        }
      });
    }

    _initializeWebSocketConnection();
    _startElapsedBlocksPolling();

    // Clear private input x when joining a game in 'created' state
    // (Player 2 should enter their own secret number)
    if ((_latestStatus == 'created') && (_myRole == 'Player 2')) {
      _controllerX.text = '';
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _closeWebSocketConnection();
    _stopElapsedBlocksPolling();
    super.dispose();
  }

  Future<void> _initializeWebSocketConnection() async {
    try {
      final contractAddress = dotenv.env['CONTRACT_ADDRESS'];
      if (contractAddress == null || contractAddress.isEmpty) {
        return;
      }

      final wsUrl = dotenv.env['STARKNET_WSS'];
      if (wsUrl == null || wsUrl.isEmpty) {
        throw Exception('STARKNET_WSS not found in .env file');
      }

      _wsChannel = StarknetWebSocketChannel(nodeUrl: wsUrl);
      await _wsChannel!.waitForConnection();
      _isConnected = _wsChannel!.isConnected();
      if (!_isConnected) {
        throw Exception('Failed to establish WebSocket connection');
      }
      if (mounted) {
        setState(() => _isConnected = true);
      }
      await _subscribeToContractEvents(contractAddress);
    } catch (_) {
      if (mounted) setState(() => _isConnected = false);
    }
  }

  void _startElapsedBlocksPolling() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _fetchElapsedBlocks();
      await _fetchLatestStatus();
    });
    _fetchElapsedBlocks();
    _fetchLatestStatus();
  }

  void _stopElapsedBlocksPolling() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  Future<void> _fetchElapsedBlocks() async {
    try {
      if (_controllerGameId.text.isEmpty) return;
      final gameId = BigInt.tryParse(_controllerGameId.text);
      if (gameId == null) return;
      final elapsed = await getElapsedBlocks(Uint256.fromBigInt(gameId));
      if (!mounted) return;
      setState(() {
        _elapsedBlocks = elapsed.toBigInt().toString();
      });
    } catch (_) {}
  }

  Future<void> _fetchLatestStatus() async {
    try {
      if (_controllerGameId.text.isEmpty) return;
      final gameId = BigInt.tryParse(_controllerGameId.text);
      if (gameId == null) return;
      final properties = await getGameProperties(Uint256.fromBigInt(gameId));
      if (!mounted) return;

      // Determine role by comparing current account with game players
      if (_myRole == null && widget.accountAddress.isNotEmpty) {
        try {
          final currentAccountFelt = Felt.fromHexString(widget.accountAddress);
          if (properties.player1 == currentAccountFelt) {
            setState(() => _myRole = 'Player 1');
          } else if (properties.player2 == currentAccountFelt) {
            setState(() => _myRole = 'Player 2');
          }
        } catch (_) {}
      }

      // if controllerY is empty then set it to the value of the last intent
      if ((_controllerY.text.isEmpty) &&
          ((_myRole == 'Player 1' && properties.status == 'p1_verify') ||
              (_myRole == 'Player 2' && properties.status == 'p2_verify'))) {
        _controllerY.text = properties.lastIntent.toString();
      }

      // if controllerBetAmount is empty then set it to the value of the bet amount
      if (_myRole == 'Player 2') {
        _controllerBetAmount.text = properties.reward.toString();
      }

      setState(() => _latestStatus = properties.status);
    } catch (_) {}
  }

  Future<void> _subscribeToContractEvents(String contractAddress) async {
    try {
      _wsChannel!.onEvents = (channel, response) async {
        _handleContractEvent(response.result.event);
      };
      final contractAddressFelt = Felt.fromHexString(contractAddress);
      await _wsChannel!.subscribeEvents(contractAddressFelt, [], null);
    } catch (_) {}
  }

  void _handleContractEvent(dynamic event) {
    try {
      final eventData = event;
      final gameId = _extractGameIdFromEvent(eventData);
      final status = _extractStatusFromEvent(eventData);
      final value = _extractValueFromEvent(eventData);

      setState(() {
        gameState = {
          'lastEvent': eventData,
          'timestamp': DateTime.now().toIso8601String(),
          'gameId': gameId,
          'status': status,
          'value': value,
          'transactionHash': _extractTransactionHash(eventData),
          'blockNumber': _extractBlockNumber(eventData),
        };
      });

      if (_myRole == 'Player 1' && status == 'p1_verify' && value != null) {
        _controllerY.text = value;
      }
      if (_myRole == 'Player 2' && status == 'p2_verify' && value != null) {
        _controllerY.text = value;
      }
    } catch (_) {}
  }

  String? _extractGameIdFromEvent(dynamic eventData) {
    if (eventData is EmittedEvent) {
      try {
        return eventData.keys[1].toBigInt().toString();
      } catch (_) {
        return eventData.keys[1].toString();
      }
    }
    return null;
  }

  String? _extractStatusFromEvent(dynamic eventData) {
    if (eventData is EmittedEvent) {
      Felt felt = eventData.data[0];
      return felt.toSymbol();
    }
    return null;
  }

  String? _extractValueFromEvent(dynamic eventData) {
    if (eventData is EmittedEvent) {
      try {
        return eventData.data[1].toBigInt().toString();
      } catch (_) {
        return eventData.data[1].toString();
      }
    }
    return null;
  }

  String? _extractTransactionHash(dynamic eventData) {
    if (eventData is EmittedEvent) {
      return eventData.transactionHash.toHexString();
    }
    return null;
  }

  String? _extractBlockNumber(dynamic eventData) {
    if (eventData is EmittedEvent) {
      return eventData.blockNumber.toString();
    }
    return null;
  }

  Future<void> _calculateCommitment() async {
    try {
      if (_controllerX.text.isEmpty) {
        return;
      }
      final x = BigInt.parse(_controllerX.text);
      final commitment = computeCommitment(x);
      //Store x, salt and hash in FlutterSecureStorage
      await _storage.write(
        key: 'x_${widget.accountAddress}',
        value: x.toString(),
      );
      await _storage.write(
        key: 'salt_${widget.accountAddress}',
        value: commitment.salt.toString(),
      );
      await _storage.write(
        key: 'hash_${widget.accountAddress}',
        value: commitment.hash.toString(),
      );
    } catch (e) {
      setState(() => _error = Exception("Error calculating hash: $e"));
    }
  }

  Future<void> _closeWebSocketConnection() async {
    try {
      if (_eventSubscriptionId != null && _wsChannel != null) {
        await _wsChannel!.unsubscribeEvents();
        _eventSubscriptionId = null;
      }
      if (_wsChannel != null && _wsChannel!.isConnected()) {
        await _wsChannel!.disconnect();
        await _wsChannel!.waitForDisconnect();
      }
      if (mounted) setState(() => _isConnected = false);
    } catch (_) {}
  }

  String? get _currentStatus {
    return _latestStatus ?? gameState?['status'];
  }

  bool _isTimeoutLoser() {
    if (_elapsedBlocks == null || _latestStatus == null || _myRole == null) {
      return false;
    }
    try {
      final elapsed = BigInt.parse(_elapsedBlocks!);
      if (elapsed > BigInt.from(1000)) {
        return (_myRole == 'Player 1' && _latestStatus == 'p1_turn') ||
            (_myRole == 'Player 2' && _latestStatus == 'p2_turn') ||
            (_myRole == 'Player 1' && _latestStatus == 'p1_verify') ||
            (_myRole == 'Player 2' && _latestStatus == 'p2_verify');
      }
    } catch (_) {}
    return false;
  }

  bool _shouldShowGameId() {
    // Always show game_id field as it's needed for game creation and to display current game
    return true;
  }

  bool _shouldEnableGameId() {
    // Disable Game ID when initialGameId is -1 (it's pre-calculated)
    if (widget.initialGameId == '-1') return false;
    final status = _currentStatus;
    // Disable once game is created or has any other status
    if (status == null || status.isEmpty || status == 'empty') return false;
    return false;
  }

  bool _shouldShowCreateGameButton() {
    // Show create button when initialGameId is -1 and game not yet created
    if (widget.initialGameId != '-1') return false;
    final status = _currentStatus;
    // Hide button after game is created
    if (status != '') return false;
    return true;
  }

  bool _shouldShowControllerX() {
    final status = _currentStatus;
    if (status == null || status.isEmpty) return true; // empty state
    return status != 'empty';
  }

  bool _shouldShowControllerMyGuess() {
    // Don't show if user timed out
    if (_isTimeoutLoser()) return false;
    final status = _currentStatus;
    if (status == null || status.isEmpty) return false;
    if (status == 'p1_turn' && _myRole == 'Player 1') return true;
    if (status == 'p2_turn' && _myRole == 'Player 2') return true;
    if (status == 'win_p1' && _myRole == 'Player 1') return true;
    if (status == 'win_p2' && _myRole == 'Player 2') return true;
    return false;
  }

  bool _shouldShowControllerY() {
    final status = _currentStatus;
    if (status == null || status.isEmpty) return false;
    if (status == 'p1_verify' && _myRole == 'Player 1') return true;
    if (status == 'p2_verify' && _myRole == 'Player 2') return true;
    return false;
  }

  bool _shouldShowSendMyGuessButton() {
    // Don't show if user timed out
    if (_isTimeoutLoser()) return false;
    final status = _currentStatus;
    if (status == null || status.isEmpty) return false;
    if (status == 'p1_turn' && _myRole == 'Player 1') return true;
    if (status == 'p2_turn' && _myRole == 'Player 2') return true;
    return false;
  }

  bool _shouldShowVerifyButton() {
    final status = _currentStatus;
    if (status == null || status.isEmpty) return false;
    if (status == 'p1_verify' && _myRole == 'Player 1') return true;
    if (status == 'p2_verify' && _myRole == 'Player 2') return true;
    return false;
  }

  bool _shouldShowClaimButton() {
    final status = _currentStatus;
    if (status == null || status.isEmpty) return false;
    if (status == 'win_p1' && _myRole == 'Player 1') return true;
    if (status == 'win_p2' && _myRole == 'Player 2') return true;
    // Show claim button if opponent timed out (elapsed blocks > 1000)
    if ((_myRole == 'Player 1') && (_latestStatus! == 'p1_turn')) return false;
    if ((_myRole == 'Player 2') && (_latestStatus! == 'p2_turn')) return false;
    if ((_myRole == 'Player 1') && (_latestStatus! == 'p1_verify')) {
      return false;
    }
    if ((_myRole == 'Player 2') && (_latestStatus! == 'p2_verify')) {
      return false;
    }
    if (_elapsedBlocks != null && _latestStatus != 'created') {
      try {
        final elapsed = BigInt.parse(_elapsedBlocks!);
        if (elapsed > BigInt.from(1000)) return true;
      } catch (_) {}
    }
    return false;
  }

  bool _shouldShowTimeoutWinnerCard() {
    if (_elapsedBlocks == null ||
        _latestStatus == null ||
        _latestStatus!.isEmpty) {
      return false;
    }
    if (_latestStatus! == 'created') return false;
    if ((_myRole == 'Player 1') && (_latestStatus! == 'p1_turn')) return false;
    if ((_myRole == 'Player 2') && (_latestStatus! == 'p2_turn')) return false;
    if ((_myRole == 'Player 1') && (_latestStatus! == 'p1_verify')) {
      return false;
    }
    if ((_myRole == 'Player 2') && (_latestStatus! == 'p2_verify')) {
      return false;
    }
    final elapsed = BigInt.tryParse(_elapsedBlocks!);
    if (elapsed == null) return false;
    return elapsed > BigInt.from(1000);
  }

  bool _shouldShowJoinGameButton() {
    final status = _currentStatus;
    // Show join button when game is in 'created' state (Player 2 joining)
    return status == 'created' && _myRole != 'Player 1';
  }

  bool _shouldEnableControllerX() {
    final status = _currentStatus;
    // Enable when initialGameId is -1 (create game mode) and game not yet created
    if (widget.initialGameId == '-1') {
      // Disable x after game is created (status is 'created' and user is Player 1)
      if (status != '' && _myRole == 'Player 1') return false;
      return true;
    }
    if (status == null || status.isEmpty) return true;
    if (status == 'empty') return true;
    if (status == 'created' && _myRole == 'Player 2') {
      return true; // Enable when game is created (Player 2 can join)
    }
    return false;
  }

  bool _shouldEnableControllerMyGuess() {
    // Disable if user timed out
    if (_isTimeoutLoser()) return false;
    final status = _currentStatus;
    if (status == null || status.isEmpty) return false;
    if (status == 'p1_turn' && _myRole == 'Player 1') return true;
    if (status == 'p2_turn' && _myRole == 'Player 2') return true;
    // win states should be disabled
    return false;
  }

  bool _shouldEnableControllerY() {
    // Controller Y should always be disabled when shown
    return false;
  }

  bool _shouldEnableControllerBetAmount() {
    if ((_myRole == 'Player 1') && (_latestStatus != '')) return false;
    if (_myRole == 'Player 2') return false;
    return true;
  }

  Widget _buildCircomTab() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _isConnected ? Icons.wifi : Icons.wifi_off,
                      color: _isConnected ? Colors.green : Colors.red,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isConnected ? 'Connected to Starknet' : 'Disconnected',
                      style: TextStyle(
                        color: _isConnected ? Colors.green : Colors.red,
                        fontSize: 12,
                      ),
                    ),
                    if (_myRole != null) ...[
                      const SizedBox(width: 12),
                      Text(
                        'Role: $_myRole',
                        style: const TextStyle(
                          color: Colors.teal,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
                if (_elapsedBlocks != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      'Elapsed blocks since last intent: $_elapsedBlocks',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.deepPurple,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (_currentStatus != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      'Latest Status: $_currentStatus',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Inputs and actions
          if (_shouldShowGameId())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextFormField(
                controller: _controllerGameId,
                enabled: _shouldEnableGameId(),
                decoration: InputDecoration(
                  labelText: "Game ID",
                  hintText: "For example, 1",
                  disabledBorder: _shouldEnableGameId()
                      ? null
                      : const OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.grey),
                        ),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          // Bet Amount textbox
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextFormField(
              controller: _controllerBetAmount,
              enabled: _shouldEnableControllerBetAmount(),
              decoration: InputDecoration(
                labelText: "Bet Amount (in STRK tokens)",
                hintText: "Enter bet amount in STRK tokens",
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove),
                      onPressed: () {
                        final currentValue =
                            int.tryParse(_controllerBetAmount.text) ?? 0;
                        if (currentValue > 0) {
                          _controllerBetAmount.text = (currentValue - 1)
                              .toString();
                        }
                      },
                      tooltip: 'Decrement',
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () {
                        final currentValue =
                            int.tryParse(_controllerBetAmount.text) ?? 0;
                        _controllerBetAmount.text = (currentValue + 1)
                            .toString();
                      },
                      tooltip: 'Increment',
                    ),
                  ],
                ),
              ),
              keyboardType: TextInputType.number,
            ),
          ),
          if (_shouldShowControllerX())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextFormField(
                controller: _controllerX,
                enabled: _shouldEnableControllerX(),
                decoration: InputDecoration(
                  labelText: "Private input `x` (My secret number)",
                  hintText: "For example, 42",
                  disabledBorder: _shouldEnableControllerX()
                      ? null
                      : const OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.grey),
                        ),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          if (_shouldShowControllerMyGuess())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextFormField(
                controller: _controllerMyGuess,
                enabled: _shouldEnableControllerMyGuess(),
                decoration: InputDecoration(
                  labelText: "My guess of opponent's number",
                  disabledBorder: _shouldEnableControllerMyGuess()
                      ? null
                      : const OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.grey),
                        ),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          if (_shouldShowControllerY())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextFormField(
                controller: _controllerY,
                enabled: _shouldEnableControllerY(),
                decoration: InputDecoration(
                  labelText: "Public input `y` (Opponent's guess)",
                  hintText: "For example, 42",
                  disabledBorder: _shouldEnableControllerY()
                      ? null
                      : const OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.grey),
                        ),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          // Waiting for opponent's verification
          if ((_currentStatus == 'p1_verify' && _myRole == 'Player 2') ||
              (_currentStatus == 'p2_verify' && _myRole == 'Player 1'))
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.hourglass_empty,
                            color: Colors.orange.shade700,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Waiting for opponent\'s verification',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange.shade900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Opponent has only 1000 blocks to verify your guess. If they fail, you win!',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.orange.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_elapsedBlocks != null) ...[
                        const SizedBox(height: 12),
                        Builder(
                          builder: (context) {
                            try {
                              final elapsed = BigInt.parse(_elapsedBlocks!);
                              final maxBlocks = BigInt.from(1000);
                              final blocksLeft = maxBlocks - elapsed;
                              final blocksLeftValue = blocksLeft < BigInt.zero
                                  ? BigInt.zero
                                  : blocksLeft;
                              final isWarning =
                                  blocksLeftValue < BigInt.from(100);
                              final isExpired = blocksLeft < BigInt.zero;
                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: isExpired
                                      ? Colors.green.shade50
                                      : isWarning
                                      ? Colors.red.shade50
                                      : Colors.orange.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isExpired
                                        ? Colors.green.shade300
                                        : isWarning
                                        ? Colors.red.shade300
                                        : Colors.orange.shade300,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isExpired
                                          ? Icons.check_circle
                                          : isWarning
                                          ? Icons.warning
                                          : Icons.timer,
                                      color: isExpired
                                          ? Colors.green.shade700
                                          : isWarning
                                          ? Colors.red.shade700
                                          : Colors.orange.shade700,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        isExpired
                                            ? 'Time expired! Player 1 failed to verify. You win!'
                                            : 'Blocks left: ${blocksLeftValue.toString()}',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: isExpired
                                              ? Colors.green.shade900
                                              : isWarning
                                              ? Colors.red.shade900
                                              : Colors.orange.shade900,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            } catch (e) {
                              return const SizedBox.shrink();
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          // Your guess was incorrect - Player 1's turn (p1_turn after Player 2's incorrect guess)
          if (_currentStatus == 'p1_turn' &&
              _myRole == 'Player 2' &&
              _controllerMyGuess.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.hourglass_empty,
                            color: Colors.orange.shade700,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Your guess was incorrect',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange.shade900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Now it\'s Player 1\'s turn to guess. Player 1 has only 1000 blocks to send their guess. If they fail, you win!',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.orange.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_elapsedBlocks != null) ...[
                        const SizedBox(height: 12),
                        Builder(
                          builder: (context) {
                            try {
                              final elapsed = BigInt.parse(_elapsedBlocks!);
                              final maxBlocks = BigInt.from(1000);
                              final blocksLeft = maxBlocks - elapsed;
                              final blocksLeftValue = blocksLeft < BigInt.zero
                                  ? BigInt.zero
                                  : blocksLeft;
                              final isWarning =
                                  blocksLeftValue < BigInt.from(100);
                              final isExpired = blocksLeft < BigInt.zero;
                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: isExpired
                                      ? Colors.green.shade50
                                      : isWarning
                                      ? Colors.red.shade50
                                      : Colors.orange.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isExpired
                                        ? Colors.green.shade300
                                        : isWarning
                                        ? Colors.red.shade300
                                        : Colors.orange.shade300,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isExpired
                                          ? Icons.check_circle
                                          : isWarning
                                          ? Icons.warning
                                          : Icons.timer,
                                      color: isExpired
                                          ? Colors.green.shade700
                                          : isWarning
                                          ? Colors.red.shade700
                                          : Colors.orange.shade700,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        isExpired
                                            ? 'Time expired! Player 1 failed to send guess. You win!'
                                            : 'Blocks left: ${blocksLeftValue.toString()}',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: isExpired
                                              ? Colors.green.shade900
                                              : isWarning
                                              ? Colors.red.shade900
                                              : Colors.orange.shade900,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            } catch (e) {
                              return const SizedBox.shrink();
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          // Create game with commitment (shown when initialGameId is -1)
          if (_shouldShowCreateGameButton())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: OutlinedButton(
                onPressed: () async {
                  if (_controllerGameId.text.isEmpty ||
                      _controllerX.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Please enter Game ID and your secret number',
                        ),
                      ),
                    );
                    return;
                  }
                  try {
                    // alert user to approve entry fee
                    // if cancel then return
                    final bool? approved = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text("Confirm Charge"),
                        content: const Text(
                          "Please approve the bet amount to create a game.",
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text("Cancel"),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text("Approve"),
                          ),
                        ],
                      ),
                    );
                    if (approved == false) return;

                    try {
                      final entryFee = Uint256.fromBigInt(
                        BigInt.parse(_controllerBetAmount.text), //1 FRI
                      );
                      final txHash = await approveEntryFee(entryFee);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            "Entry fee approved successfully: $txHash",
                          ),
                        ),
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Error approving entry fee: $e"),
                        ),
                      );
                      return;
                    }
                    await _calculateCommitment();
                    final gameId = BigInt.parse(_controllerGameId.text);
                    final hash = await _storage.read(
                      key: 'hash_${widget.accountAddress}',
                    );
                    final hashU256 = Uint256.fromBigInt(BigInt.parse(hash!));
                    final gameIdU256 = Uint256.fromBigInt(gameId);
                    final txHash = await invokeCreateGame(
                      gameIdU256,
                      hashU256,
                      Uint256.fromBigInt(
                        BigInt.parse(_controllerBetAmount.text),
                      ),
                    );
                    if (mounted) {
                      setState(() => _myRole = 'Player 1');
                      // Refresh status to update UI
                      _fetchLatestStatus();
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          "Commitment registered successfully: $txHash",
                        ),
                      ),
                    );
                  } catch (e) {
                    setState(() => _error = Exception("Error: $e"));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Error creating game: $e")),
                    );
                  }
                },
                child: const Text("Create game (save commitment)"),
              ),
            ),
          // Join Game button (shown when game is in 'created' state)
          if (_shouldShowJoinGameButton())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: OutlinedButton(
                onPressed: () async {
                  if (_controllerGameId.text.isEmpty ||
                      _controllerX.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Please enter your secret number and wait for salt to be generated',
                        ),
                      ),
                    );
                    return;
                  }
                  try {
                    // alert user to approve entry fee
                    final bool? approved = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text("Confirm Charge"),
                        content: const Text(
                          "Please approve the bet amount to join the game.",
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text("Cancel"),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text("Approve"),
                          ),
                        ],
                      ),
                    );
                    if (approved == false) return;

                    try {
                      final entryFee = Uint256.fromBigInt(
                        BigInt.parse(_controllerBetAmount.text), //1 FRI
                      );
                      final txHash = await approveEntryFee(entryFee);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            "Entry fee approved successfully: $txHash",
                          ),
                        ),
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Error approving entry fee: $e"),
                        ),
                      );
                      return;
                    }
                    await _calculateCommitment();
                    final gameId = BigInt.parse(_controllerGameId.text);
                    final hash = await _storage.read(
                      key: 'hash_${widget.accountAddress}',
                    );
                    final gameIdU256 = Uint256.fromBigInt(gameId);
                    final hashU256 = Uint256.fromBigInt(BigInt.parse(hash!));
                    final txHash = await invokeJoinGame(gameIdU256, hashU256);
                    if (mounted) {
                      setState(() {
                        _myRole = 'Player 2';
                      });
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("Game joined successfully: $txHash"),
                      ),
                    );
                  } catch (e) {
                    setState(() => _error = Exception("Error: $e"));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Error joining game: $e")),
                    );
                  }
                },
                child: const Text("Join Game (save commitment)"),
              ),
            ),
          // Waiting for opponent's guess intent (initial state - before Player 2 makes a guess)
          if ((_currentStatus == 'p1_turn' && _myRole == 'Player 2') ||
              (_currentStatus == 'p2_turn' && _myRole == 'Player 1'))
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.hourglass_empty,
                            color: Colors.orange.shade700,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _controllerMyGuess.text.isNotEmpty
                                      ? 'You Fail!!!. Waiting for opponent\'s guess intent'
                                      : 'Waiting for opponent\'s guess intent',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange.shade900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Opponent has only 1000 blocks to send their guess. If they fail, you win!',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.orange.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_elapsedBlocks != null) ...[
                        const SizedBox(height: 12),
                        Builder(
                          builder: (context) {
                            try {
                              final elapsed = BigInt.parse(_elapsedBlocks!);
                              final maxBlocks = BigInt.from(1000);
                              final blocksLeft = maxBlocks - elapsed;
                              final blocksLeftValue = blocksLeft < BigInt.zero
                                  ? BigInt.zero
                                  : blocksLeft;
                              final isWarning =
                                  blocksLeftValue < BigInt.from(100);
                              final isExpired = blocksLeft < BigInt.zero;
                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: isExpired
                                      ? Colors.green.shade50
                                      : isWarning
                                      ? Colors.red.shade50
                                      : Colors.orange.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isExpired
                                        ? Colors.green.shade300
                                        : isWarning
                                        ? Colors.red.shade300
                                        : Colors.orange.shade300,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isExpired
                                          ? Icons.check_circle
                                          : isWarning
                                          ? Icons.warning
                                          : Icons.timer,
                                      color: isExpired
                                          ? Colors.green.shade700
                                          : isWarning
                                          ? Colors.red.shade700
                                          : Colors.orange.shade700,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        isExpired
                                            ? 'Time expired! Opponent failed to send guess. You win!'
                                            : 'Blocks left: ${blocksLeftValue.toString()}',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: isExpired
                                              ? Colors.green.shade900
                                              : isWarning
                                              ? Colors.red.shade900
                                              : Colors.orange.shade900,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            } catch (e) {
                              return const SizedBox.shrink();
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          // Waiting for Player 2 message
          if (_currentStatus == 'created' && _myRole == 'Player 1')
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue.shade700),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Waiting for Player 2',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Share the Game ID with a friend to join the game!',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.blue.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.copy, color: Colors.blue.shade700),
                        tooltip: 'Copy Game ID',
                        onPressed: () {
                          if (_controllerGameId.text.isNotEmpty) {
                            Clipboard.setData(
                              ClipboardData(text: _controllerGameId.text),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Game ID copied to clipboard'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Send my guess (write_intent)
          if (_shouldShowSendMyGuessButton())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: OutlinedButton(
                onPressed: () async {
                  try {
                    final gameId = BigInt.parse(_controllerGameId.text);
                    final guess = BigInt.parse(_controllerMyGuess.text);
                    final gameIdU256 = Uint256.fromBigInt(gameId);
                    final guessU256 = Uint256.fromBigInt(guess);
                    final txHash = await invokeWriteIntent(
                      gameIdU256,
                      guessU256,
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("My guess sent successfully: $txHash"),
                      ),
                    );
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Error sending my guess: $e")),
                    );
                  }
                },
                child: const Text("Send My Guess to the opponent."),
              ),
            ),
          // Generate proof locally - hidden from user per requirement
          // Verify / Check result
          if (_shouldShowVerifyButton())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: OutlinedButton(
                onPressed: () async {
                  if (_controllerX.text.isEmpty ||
                      _controllerY.text.isEmpty ||
                      isProving) {
                    return;
                  }
                  setState(() {
                    _error = null;
                    isProving = true;
                  });
                  FocusManager.instance.primaryFocus?.unfocus();
                  bool? valid;
                  try {
                    // Generate proof first
                    final salt = await _storage.read(
                      key: 'salt_${widget.accountAddress}',
                    );
                    final hash = await _storage.read(
                      key: 'hash_${widget.accountAddress}',
                    );
                    final calldataElements = await proveAndBuildGaragaCalldata(
                      x: BigInt.parse(_controllerX.text),
                      salt: BigInt.parse(salt!),
                      h: BigInt.parse(hash!),
                      y: BigInt.parse(_controllerY.text),
                    );

                    final txHash = await invokeVerifyIntent(
                      Uint256.fromBigInt(BigInt.parse(_controllerGameId.text)),
                      calldataElements,
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("Proof verified successfully: $txHash"),
                      ),
                    );
                    valid = true;
                  } catch (e) {
                    valid =
                        false; //"Invalid Proof JSON: Error("invalid type: map, expected a sequence", line: 1, column: 5)"
                    setState(() => _error = Exception(e.toString()));
                  }
                  if (!mounted) return;
                  setState(() {
                    isProving = false;
                    _circomValid = valid;
                  });
                },
                // button with centered text
                child: Center(
                  child: Text(
                    "Guess received, press button to check result \n (verify proof onchain)",
                    style: TextStyle(fontSize: 15),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          // Winner Card (win_p1 or win_p2)
          if ((_currentStatus == 'win_p1' && _myRole == 'Player 1') ||
              (_currentStatus == 'win_p2' && _myRole == 'Player 2'))
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                color: Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.emoji_events,
                            color: Colors.yellow.shade700,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '🎉 Congratulations! You are the Winner! 🎉',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green.shade900,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'You have great ESP (Extrasensory Perception) powers! Your psychic abilities are truly impressive! 🔮✨',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.green.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Loser Card (win_p2 when Player 1, or win_p1 when Player 2)
          if ((_currentStatus == 'win_p2' && _myRole == 'Player 1') ||
              (_currentStatus == 'win_p1' && _myRole == 'Player 2'))
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                color: Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.sentiment_dissatisfied,
                            color: Colors.red.shade700,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '😔 Better luck next time!',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red.shade900,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Your opponent has proven to have stronger ESP powers this time. Don\'t give up - your psychic abilities may improve with practice! 🎯',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.red.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Timeout Loser Card (elapsed blocks > 1000 and user is in their turn/verify state)
          if (_elapsedBlocks != null && _latestStatus != null)
            Builder(
              builder: (context) {
                try {
                  final elapsed = BigInt.parse(_elapsedBlocks!);
                  if (elapsed > BigInt.from(1000)) {
                    // Check if user timed out during their turn or verify phase
                    final isTimeoutLoser =
                        (_myRole == 'Player 1' && _latestStatus == 'p1_turn') ||
                        (_myRole == 'Player 2' && _latestStatus == 'p2_turn') ||
                        (_myRole == 'Player 1' &&
                            _latestStatus == 'p1_verify') ||
                        (_myRole == 'Player 2' && _latestStatus == 'p2_verify');

                    if (isTimeoutLoser) {
                      return Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Card(
                          color: Colors.red.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.sentiment_dissatisfied,
                                      color: Colors.red.shade700,
                                      size: 32,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '⏰ Time\'s Up! You Lost!',
                                            style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.red.shade900,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            'You failed to act within the time limit. Your opponent wins by default. Better luck next time! 🎯',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Colors.red.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                  }
                } catch (_) {}
                return const SizedBox.shrink();
              },
            ),
          // Timeout Winner Card (elapsed blocks > 1000)
          if (_shouldShowTimeoutWinnerCard())
            Builder(
              builder: (context) {
                try {
                  final elapsed = BigInt.parse(_elapsedBlocks!);
                  if (elapsed > BigInt.from(1000)) {
                    return Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Card(
                        color: Colors.green.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.emoji_events,
                                    color: Colors.yellow.shade700,
                                    size: 32,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '🎉 Congratulations! You are the Winner! 🎉',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green.shade900,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'Your opponent failed to act in time! You have great ESP (Extrasensory Perception) powers! Your patience and timing abilities are truly impressive! 🔮✨',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Colors.green.shade700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                } catch (_) {}
                return const SizedBox.shrink();
              },
            ),
          // Claim Reward
          if (_shouldShowClaimButton())
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: OutlinedButton(
                onPressed: () async {
                  if (_controllerGameId.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a Game ID')),
                    );
                    return;
                  }
                  try {
                    final gameId = BigInt.parse(_controllerGameId.text);
                    final gameIdU256 = Uint256.fromBigInt(gameId);
                    final txHash = await invokeClaimReward(gameIdU256);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("Reward claimed successfully: $txHash"),
                      ),
                    );
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Error claiming reward: $e")),
                    );
                  }
                },
                child: const Text("Claim Reward"),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZK Extrasensory Perception (ESP) Game'),
        actions: [
          if (widget.accountAddress.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy account address',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.accountAddress));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Account address copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              text: widget.accountAddress.isNotEmpty
                  ? 'Account: ${widget.accountAddress.substring(0, 6)}...${widget.accountAddress.substring(widget.accountAddress.length - 4)}'
                  : 'Circom',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildCircomTab()],
      ),
    );
  }
}
