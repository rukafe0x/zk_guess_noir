import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mopro_flutter_bindings/mopro_flutter_bindings.dart';
import 'package:starknet/starknet.dart';
import 'account_selection_screen.dart';
import 'services.dart';
import 'main_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Extrasensory Perception (ESP)',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
        useMaterial3: true,
        appBarTheme: AppBarTheme(
          backgroundColor: Color(0xFFF76300),
          foregroundColor: Colors.white,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),
      ),
      home: const AccountSelectionScreen(),
    );
  }
}

class SeedPhraseScreen extends StatefulWidget {
  const SeedPhraseScreen({Key? key}) : super(key: key);

  @override
  _SeedPhraseScreenState createState() => _SeedPhraseScreenState();
}

class _SeedPhraseScreenState extends State<SeedPhraseScreen> {
  final TextEditingController _seedController = TextEditingController(
    text: dotenv.env['SEED_PHRASE'] ?? '',
  );
  final TextEditingController _addressController = TextEditingController(
    text: dotenv.env['SECRET_ACCOUNT_ADDRESS'] ?? '',
  );
  final _formKey = GlobalKey<FormState>();

  Felt _owner = Felt.fromHexString('0x0');

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _seedController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _validateAndContinue() async {
    if (_formKey.currentState!.validate()) {
      String seedPhrase = _seedController.text.trim();
      String accountAddress = _addressController.text.trim();

      if (seedPhrase.isEmpty || accountAddress.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Por favor, completa todos los campos')),
        );
      } else {
        try {
          // Generate private key from seed phrase, prefix with 0x and pad with 0s to 64 characters
          String privateKey = await _generatePrivateKey(seedPhrase);
          // mod privatekey with stark prime number
          final starkPrime = BigInt.parse(
            '3618502788666131213697322783095070105623107215331596699973092056135872020481',
          );
          privateKey =
              (BigInt.parse(privateKey.substring(2), radix: 16) % starkPrime)
                  .toRadixString(16);
          privateKey = privateKey.padLeft(64, '0');
          privateKey = '0x' + privateKey;
          privateKey = dotenv.env['SECRET_ACCOUNT_ADDRESS'] ?? '';
          print(privateKey);
          // Here you would typically store or use the private key securely
          // For demonstration, we're just showing it in a SnackBar
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Clave privada generada: $privateKey')),
          );

          final signeraccount = getAccount(
            accountAddress: Felt.fromHexString(accountAddress),
            privateKey: Felt.fromHexString(privateKey),
            nodeUri: Uri.parse(dotenv.env['STARKNET_NODE_URI'] ?? ''),
          );

          // display signeraccount address as hex in snackbar
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Dirección de la cuenta: ${signeraccount.accountAddress.toHexString()}',
              ),
            ),
          );

          //Ensure initstate is already finished the execution of getOwner()
          await Future.delayed(Duration.zero);

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MainScreen(
                accountAddress: signeraccount.accountAddress.toHexString(),
                accountNickname: 'Extrasensory Perception (ESP)',
              ),
            ),
          );
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error al generar la clave privada: $e')),
          );
        }
      }
    }
  }

  Future<String> _generatePrivateKey(String seedPhrase) async {
    //wrong implementation
    final privateKey = derivePrivateKey(mnemonic: seedPhrase);
    return privateKey.toHexString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text(
          'Ingresa tu Seed Phrase',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF6750A4),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Ingresa las 12 palabras de tu seed phrase',
                          style: TextStyle(color: Colors.black54, fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _seedController,
                          maxLines: 6,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.grey.shade50,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                            hintText: 'palabra1 palabra2 palabra3...',
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Por favor ingresa tu seed phrase';
                            }
                            final wordCount = value.trim().split(' ').length;
                            if (wordCount != 12) {
                              return 'La seed phrase debe contener exactamente 12 palabras';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Ingresa la dirección de tu cuenta',
                          style: TextStyle(color: Colors.black54, fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _addressController,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.grey.shade50,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                            hintText: '0x...',
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Por favor ingresa la dirección de tu cuenta';
                            }
                            // Add more specific validation for St
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _validateAndContinue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6750A4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text(
                    'Continuar',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Nunca compartas tu seed phrase con nadie.\nGuárdala en un lugar seguro.',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
