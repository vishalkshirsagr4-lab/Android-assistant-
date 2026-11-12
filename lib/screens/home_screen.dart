import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/agent_controller.dart';
import '../services/app_update_service.dart';
import '../services/grok_service.dart';
import '../services/lucy_activity_store.dart';
import '../services/performance_monitor.dart';
import '../widgets/lucy_avatar.dart';

class HomeScreen extends StatefulWidget {
  final AgentController controller;

  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _apiKeyController = TextEditingController();
  final AppUpdateService _appUpdateService = AppUpdateService();
  final GrokService _grokService = GrokService();
  final LucyActivityStore _activityStore = LucyActivityStore();
  final LucyPerformanceMonitor _performanceMonitor = LucyPerformanceMonitor();
  bool _updateCheckStarted = false;
  DateTime? _lastUpdateCheckAt;

  bool _isAccessibilityEnabled = false;
  bool _isCheckingAccessibility = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    widget.controller.addListener(_onControllerUpdate);
    _loadApiKey();

    _checkAccessibility();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForAppUpdate();
    });
  }

  Future<void> _checkForAppUpdate() async {
    if (!Platform.isAndroid || _updateCheckStarted || !mounted) return;
    final now = DateTime.now();
    if (_lastUpdateCheckAt != null &&
        now.difference(_lastUpdateCheckAt!) < const Duration(minutes: 5)) {
      return;
    }
    _updateCheckStarted = true;
    _lastUpdateCheckAt = now;
    try {
      final update = await _appUpdateService.checkForUpdate();
      if (!mounted || update == null) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.system_update_alt, size: 34),
          title: Text('Lucy update available · ${update.version}'),
          content: SingleChildScrollView(
            child: Text(
              update.notes.isEmpty
                  ? 'A newer version of Lucy is ready to install.'
                  : update.notes.length > 1400
                      ? '${update.notes.substring(0, 1400)}…'
                      : update.notes,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Later'),
            ),
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(dialogContext);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Downloading Lucy update…')),
                );
                try {
                  final installerOpened =
                      await _appUpdateService.downloadAndInstall(update);
                  if (!mounted) return;
                  if (!installerOpened) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Allow Lucy to install unknown apps in Settings. The update will continue when you return.',
                        ),
                        duration: Duration(seconds: 6),
                      ),
                    );
                  }
                } catch (error) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Update failed: $error')),
                  );
                }
              },
              icon: const Icon(Icons.download),
              label: const Text('Download & install'),
            ),
          ],
        ),
      );
    } catch (error) {
      // Keep Lucy usable offline, but allow another check after a later resume.
      debugPrint('Lucy update check failed: $error');
    } finally {
      _updateCheckStarted = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibility();
      unawaited(_appUpdateService.resumePendingInstall());
      // Retry release checks after returning online or from Android settings.
      unawaited(_checkForAppUpdate());
    }
  }

  Future<void> _checkAccessibility() async {
    if (mounted && !_isCheckingAccessibility) {
      setState(() => _isCheckingAccessibility = true);
    }

    final isEnabled = await widget.controller.screenCapture
        .isAccessibilityEnabled();

    if (mounted) {
      setState(() {
        _isAccessibilityEnabled = isEnabled;
        _isCheckingAccessibility = false;
      });
    }
  }

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('gemini_api_key');
    if (key != null && key.isNotEmpty) {
      _apiKeyController.text = key;
      widget.controller.configureAi(key);
    }
  }

  Future<void> _saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', key);
    widget.controller.configureAi(key);
  }

  void _onControllerUpdate() {
    setState(() {});
    if (widget.controller.isActive &&
        widget.controller.state == AgentState.listening) {
      _pulseController.repeat(reverse: true);
    } else {
      _pulseController.stop();
      _pulseController.reset();
    }

    // Scroll to bottom on new messages
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _scrollController.dispose();
    _apiKeyController.dispose();
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isCheckingAccessibility) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (!_isAccessibilityEnabled) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          title: const Text('Access Required'),
          backgroundColor: colorScheme.surface,
          elevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.accessibility_new,
                  size: 72,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'Accessibility Required',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'To use this app, you must enable the Lucy accessibility service.\n\n'
                  'Go to Settings → Accessibility → Lucy → Enable',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurface.withOpacity(0.7),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: () => widget.controller.screenCapture
                      .openAccessibilitySettings(),
                  icon: const Icon(Icons.settings),
                  label: const Text('Open Settings'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.controller.isActive
                    ? Colors.greenAccent
                    : Colors.grey,
                boxShadow: widget.controller.isActive
                    ? [
                        BoxShadow(
                          color: Colors.greenAccent.withOpacity(0.5),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            const Text('Lucy'),
          ],
        ),
        backgroundColor: colorScheme.surface,
        elevation: 0,
        actions: [
          _buildLanguageToggle(),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Lucy tools and activity',
            onPressed: _showToolsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.key),
            tooltip: 'API Key',
            onPressed: () => _showApiKeyDialog(context),
          ),
          if (widget.controller.conversation.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear conversation',
              onPressed: () => widget.controller.clearConversation(),
            ),
        ],
      ),
      body: Column(
        children: [
          // Lucy is the full-screen visual focus. Status and conversation
          // cards float above the avatar so voice and chat remain accessible.
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                LucyAvatar(state: widget.controller.state),
                Positioned(
                  top: 10,
                  left: 12,
                  right: 12,
                  child: _buildStatusBar(colorScheme),
                ),
                if (widget.controller.conversation.isNotEmpty)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    height: MediaQuery.sizeOf(context).height * 0.22,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.surface.withOpacity(0.82),
                          border: Border.all(
                            color: colorScheme.outline.withOpacity(0.18),
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: _buildConversationList(colorScheme),
                      ),
                    ),
                  )
                else
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 22,
                    child: IgnorePointer(
                      child: Text(
                        'I’m here. What shall we do?',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colorScheme.onSurface.withOpacity(0.72),
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(
                              color: colorScheme.surface,
                              blurRadius: 12,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Current transcript and microphone controls remain unchanged.
          if (widget.controller.currentTranscript?.isNotEmpty == true)
            _buildTranscriptBar(colorScheme),
          _buildBottomBar(colorScheme),
        ],
      ),
    );
  }

  Widget _buildStatusBar(ColorScheme colorScheme) {
    final stateIcon = _getStateIcon();
    final statusColor = _getStatusColor();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withOpacity(0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: statusColor.withOpacity(0.22)),
      ),
      child: Row(
        children: [
          Icon(stateIcon, size: 16, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.controller.statusMessage,
              style: TextStyle(
                color: statusColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (!widget.controller.aiService.isConfigured)
            TextButton.icon(
              onPressed: () => _showApiKeyDialog(context),
              icon: Icon(Icons.warning_amber, size: 16, color: Colors.amber),
              label: Text(
                'Set API Key',
                style: TextStyle(color: Colors.amber, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }


  Widget _buildConversationList(ColorScheme colorScheme) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: widget.controller.conversation.length,
      itemBuilder: (context, index) {
        final entry = widget.controller.conversation[index];
        return _buildConversationBubble(entry, colorScheme);
      },
    );
  }

  Widget _buildConversationBubble(
    ConversationEntry entry,
    ColorScheme colorScheme,
  ) {
    final isUser = entry.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser
              ? colorScheme.primary.withOpacity(0.2)
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: isUser
                ? const Radius.circular(16)
                : const Radius.circular(4),
            bottomRight: isUser
                ? const Radius.circular(4)
                : const Radius.circular(16),
          ),
          border: Border.all(
            color: isUser
                ? colorScheme.primary.withOpacity(0.3)
                : colorScheme.outline.withOpacity(0.1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isUser ? Icons.person : Icons.smart_toy,
                  size: 14,
                  color: isUser ? colorScheme.primary : colorScheme.secondary,
                ),
                const SizedBox(width: 6),
                Text(
                  isUser ? 'You' : 'Lucy',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isUser ? colorScheme.primary : colorScheme.secondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onSurface.withOpacity(0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Screenshot preview
            if (entry.screenshotBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  entry.screenshotBytes!,
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (_, error, stackTrace) => Container(
                    height: 60,
                    color: Colors.grey[800],
                    child: const Center(
                      child: Icon(Icons.broken_image, size: 24),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SelectableText(
              entry.text,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurface,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscriptBar(ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.primary.withOpacity(0.05),
        border: Border(
          top: BorderSide(color: colorScheme.primary.withOpacity(0.2)),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.controller.currentTranscript ?? '',
              style: TextStyle(
                color: colorScheme.primary,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outline.withOpacity(0.1)),
        ),
      ),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Left area: Screenshot button
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: widget.controller.isActive
                    ? IconButton(
                        onPressed: _manualCapture,
                        icon: const Icon(Icons.camera_alt_outlined),
                        tooltip: 'Capture screen now',
                      )
                    : const SizedBox.shrink(),
              ),
            ),

            // Main mic button
            ScaleTransition(
              scale: widget.controller.state == AgentState.listening
                  ? _pulseAnimation
                  : const AlwaysStoppedAnimation(1.0),
              child: GestureDetector(
                onTap: () => widget.controller.toggleAgent(),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: widget.controller.isActive
                          ? [Colors.redAccent, Colors.red[700]!]
                          : [colorScheme.primary, colorScheme.tertiary],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (widget.controller.isActive
                                    ? Colors.redAccent
                                    : colorScheme.primary)
                                .withOpacity(0.4),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    widget.controller.isActive ? Icons.stop : Icons.mic,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
            ),

            // Right area: spacer for layout balance
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ),
    );
  }

  IconData _getStateIcon() {
    switch (widget.controller.state) {
      case AgentState.idle:
        return Icons.mic_off;
      case AgentState.listening:
        return Icons.mic;
      case AgentState.capturing:
        return Icons.camera;
      case AgentState.analyzing:
        return Icons.psychology;
      case AgentState.speaking:
        return Icons.volume_up;
      case AgentState.waitingConfirmation:
        return Icons.help_outline;
      case AgentState.executingAction:
        return Icons.flash_on;
    }
  }

  Color _getStatusColor() {
    switch (widget.controller.state) {
      case AgentState.idle:
        return Colors.grey;
      case AgentState.listening:
        return Colors.greenAccent;
      case AgentState.capturing:
        return Colors.amber;
      case AgentState.analyzing:
        return Colors.blue;
      case AgentState.speaking:
        return Colors.purple;
      case AgentState.waitingConfirmation:
        return Colors.orange;
      case AgentState.executingAction:
        return Colors.cyan;
    }
  }

  static const Map<String, String> _langBadges = {
    'en': 'EN',
    'ja': 'JA',
    'ar': 'AR',
  };

  Widget _buildLanguageToggle() {
    final current = widget.controller.currentLang;
    return PopupMenuButton<String>(
      tooltip: 'Input / reply language',
      initialValue: current,
      onSelected: (lang) => widget.controller.setLanguage(lang),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'en', child: Text('English')),
        PopupMenuItem(value: 'ja', child: Text('日本語')),
        PopupMenuItem(value: 'ar', child: Text('العربية')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 18),
            const SizedBox(width: 4),
            Text(
              _langBadges[current] ?? 'EN',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  void _showApiKeyDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gemini API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter your Google Gemini API key to enable real AI vision analysis.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'AIza...',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final key = _apiKeyController.text.trim();
              if (key.isNotEmpty) {
                _saveApiKey(key);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _showToolsDialog() async {
    final grokController = TextEditingController();
    final snapshot = _performanceMonitor.snapshot();
    final templates = await _activityStore.readAutomationTemplates();
    final configured = await _grokService.isConfigured();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lucy tools'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Performance · RAM: ${snapshot.ramLabel}'),
                Text('Last AI response: ${snapshot.lastResponseMs == null ? 'Not measured yet' : '${snapshot.lastResponseMs} ms'}'),
                const SizedBox(height: 12),
                const Text('Grok / xAI provider', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(configured ? 'API key saved securely on this device.' : 'No Grok key configured.'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use Grok 4.7 for Lucy'),
                  subtitle: const Text('Supports text and screen images. Gemini remains available.'),
                  value: widget.controller.isGrokProvider,
                  onChanged: configured
                      ? (enabled) => widget.controller.setGrokProvider(enabled)
                      : null,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: grokController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'Paste xAI API key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Automation templates', style: TextStyle(fontWeight: FontWeight.bold)),
                ...templates.map((item) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: Text(item['name']?.toString() ?? 'Routine'),
                  subtitle: const Text('Template only · approval required before actions'),
                )),
                const SizedBox(height: 8),
                const Text('Activity history is stored locally on this device. API keys, screenshots and passwords are not included.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await _grokService.clearApiKey();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Remove Grok key'),
          ),
          TextButton(
            onPressed: () async {
              final events = await _activityStore.readEvents();
              if (!ctx.mounted) return;
              await showDialog<void>(
                context: ctx,
                builder: (historyContext) => AlertDialog(
                  title: const Text('Recent activity'),
                  content: SizedBox(
                    width: double.maxFinite,
                    height: 320,
                    child: events.isEmpty
                        ? const Text('No saved activity yet.')
                        : ListView.builder(
                            itemCount: events.length,
                            itemBuilder: (_, index) {
                              final event = events[events.length - 1 - index];
                              return ListTile(
                                dense: true,
                                title: Text(event['summary']?.toString() ?? ''),
                                subtitle: Text(event['time']?.toString() ?? ''),
                              );
                            },
                          ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        await _activityStore.clearEvents();
                        if (historyContext.mounted) Navigator.pop(historyContext);
                      },
                      child: const Text('Clear history'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(historyContext),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
            child: const Text('View activity'),
          ),
          FilledButton(
            onPressed: () async {
              final key = grokController.text.trim();
              if (key.isNotEmpty) await _grokService.saveApiKey(key);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save Grok key'),
          ),
        ],
      ),
    );
    grokController.dispose();
  }

  Future<void> _manualCapture() async {
    final captured = await widget.controller.capturePreview();
    if (captured && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Screenshot captured')));
    }
  }
}
