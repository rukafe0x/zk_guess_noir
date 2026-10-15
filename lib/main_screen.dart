import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'join_game_screen.dart' as join_game;

class MainScreen extends StatelessWidget {
  final String accountAddress;
  final String accountNickname;
  const MainScreen({
    super.key,
    required this.accountAddress,
    required this.accountNickname,
  });

  String _shortAddress(String addr) {
    if (addr.isEmpty) return '';
    if (addr.length <= 12) return addr;
    return '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('ZK ESP - Main Menu'),
            if (accountAddress.isNotEmpty)
              Text(
                'Account: ${_shortAddress(accountAddress)}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
          ],
        ),
        actions: [
          if (accountAddress.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy account address',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: accountAddress));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Account address copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => join_game.GameScreen(
                        accountAddress: accountAddress,
                        accountNickname: accountNickname,
                        initialGameId: "-1", // -1 means create a new game
                      ),
                    ),
                  );
                },
                child: const Text('Create a Game'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  final gameId = await showDialog<String>(
                    context: context,
                    builder: (context) {
                      final controller = TextEditingController();
                      return AlertDialog(
                        title: const Text('Join a Game'),
                        content: TextField(
                          controller: controller,
                          decoration: const InputDecoration(
                            labelText: 'Game ID',
                            hintText: 'Enter the game ID to join',
                          ),
                          keyboardType: TextInputType.number,
                          autofocus: true,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              if (controller.text.trim().isNotEmpty) {
                                Navigator.pop(context, controller.text.trim());
                              }
                            },
                            child: const Text('Join'),
                          ),
                        ],
                      );
                    },
                  );

                  if (gameId != null && gameId.isNotEmpty) {
                    if (context.mounted) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => join_game.GameScreen(
                            accountAddress: accountAddress,
                            accountNickname: accountNickname,
                            initialGameId: gameId,
                          ),
                        ),
                      );
                    }
                  }
                },
                child: const Text('Join a Game'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
