import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'services/agent_controller.dart';
import 'services/lucy_context_builder.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LucyApp());
}

class LucyApp extends StatefulWidget {
  const LucyApp({super.key});

  @override
  State<LucyApp> createState() => _LucyAppState();
}

class _LucyAppState extends State<LucyApp> {
  late final AgentController _agentController;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _agentController = AgentController();
    _initializeLucy();
  }


  Future<void> _initializeLucy() async {
    await _agentController.initialize();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('lucy_setup_wizard_seen') ?? false) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _navigatorKey.currentContext;
      if (context != null && mounted) {
        _showFirstRunSetup(context);
      }
    });
  }

  Future<void> _showFirstRunSetup(BuildContext context) async {
    final contextBuilder = LucyContextBuilder();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Welcome to Lucy'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose the access Lucy needs. Each Android permission or special-access screen remains under your control.',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await _agentController.screenCapture.openAccessibilitySettings();
                },
                icon: const Icon(Icons.accessibility_new),
                label: const Text('Accessibility settings'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await _agentController.screenCapture.requestPermission();
                },
                icon: const Icon(Icons.screen_share_outlined),
                label: const Text('Screen capture consent'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await contextBuilder.openNotificationAccessSettings();
                },
                icon: const Icon(Icons.notifications_outlined),
                label: const Text('Notification access (optional)'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await contextBuilder.openUsageAccessSettings();
                },
                icon: const Icon(Icons.apps_outlined),
                label: const Text('Usage access (optional)'),
              ),
              const Text(
                'Calendar, microphone and Contacts permissions are requested only when you enable or use those features. You can revisit the full setup guide from Lucy Settings.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lucy_setup_wizard_seen', true);
  }

  @override
  void dispose() {
    _agentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Lucy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF6C63FF),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: HomeScreen(controller: _agentController),
    );
  }
}
