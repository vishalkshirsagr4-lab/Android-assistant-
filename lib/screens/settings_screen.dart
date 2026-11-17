import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/agent_controller.dart';
import '../services/grok_service.dart';
import '../services/groq_service.dart';
import '../services/hms_service.dart';
import '../services/lucy_context_builder.dart';
import '../services/lucy_settings_store.dart';
import '../services/proactive_decision_service.dart';
import '../services/routine_scheduler.dart';

class LucySettingsScreen extends StatefulWidget {
  const LucySettingsScreen({super.key, required this.controller});

  final AgentController controller;

  @override
  State<LucySettingsScreen> createState() => _LucySettingsScreenState();
}

class _LucySettingsScreenState extends State<LucySettingsScreen> {
  final LucySettingsStore _settings = LucySettingsStore();
  final LucyContextBuilder _context = LucyContextBuilder();
  final LucyProactiveService _proactive = LucyProactiveService();
  final GrokService _grok = GrokService();
  final GroqService _groq = GroqService();
  final HmsService _hms = HmsService();

  Map<String, bool> _values = <String, bool>{};
  Map<String, dynamic> _contextStatus = <String, dynamic>{};
  bool _calendarEnabled = false;
  bool _foregroundContextEnabled = true;
  Set<String> _excludedWatcherPackages = <String>{};
  LucyProactiveStatus _proactiveStatus = const LucyProactiveStatus(
    enabled: false,
    quietStartHour: 22,
    quietEndHour: 8,
    dailyLimit: 3,
    cooldownMinutes: 120,
  );
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final values = await _settings.readAll();
    final proactive = await _proactive.readStatus();
    final contextStatus = await _context.readStatus();
    final prefs = await SharedPreferences.getInstance();
    final calendarEnabled = prefs.getBool('lucy_context_calendar_enabled') ?? false;
    final foregroundEnabled =
        prefs.getBool(LucySettingsStore.foregroundAppContext) ?? true;
    final excludedPackages = prefs.getStringList('lucy_screen_watcher_excluded_packages')?.toSet() ?? <String>{};
    if (!mounted) return;
    setState(() {
      _values = values;
      _contextStatus = contextStatus;
      _calendarEnabled = calendarEnabled;
      _foregroundContextEnabled = foregroundEnabled;
      _excludedWatcherPackages = excludedPackages;
      _proactiveStatus = proactive;
      _loading = false;
    });
    await _applyScreenWatcherSettings(values, excludedPackages);
    if (!(prefs.getBool('lucy_setup_wizard_seen') ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSetupWizard(markSeen: true);
      });
    }
  }

  Future<void> _applyScreenWatcherSettings(
    Map<String, bool> values,
    Set<String> excludedPackages,
  ) async {
    final autopilotEnabled = values[LucySettingsStore.autopilot] ?? true;
    await widget.controller.screenCapture.configureScreenWatcher(
      enabled: autopilotEnabled &&
          (values[LucySettingsStore.screenWatcher] ?? true),
      skipAds: autopilotEnabled &&
          (values[LucySettingsStore.autoSkipAds] ?? true),
      dismissPopups: autopilotEnabled &&
          (values[LucySettingsStore.autoDismissPopups] ?? true),
      excludedPackages: excludedPackages,
    );
  }

  Future<void> _setCapability(String key, bool enabled) async {
    await _settings.setEnabled(key, enabled);
    if (const {
      LucySettingsStore.screenWatcher,
      LucySettingsStore.autoSkipAds,
      LucySettingsStore.autoDismissPopups,
      LucySettingsStore.autopilot,
    }.contains(key)) {
      final nextValues = <String, bool>{..._values, key: enabled};
      await _applyScreenWatcherSettings(nextValues, _excludedWatcherPackages);
    }
    if (key == LucySettingsStore.scheduledReminders && !enabled) {
      final routines = await LucyRoutineScheduler.listRoutines();
      for (final routine in routines) {
        final id = routine['id']?.toString();
        if (id != null && id.isNotEmpty) {
          await LucyRoutineScheduler.cancelReminder(id);
        }
      }
    }
    if (!enabled && widget.controller.isActive && const {
      LucySettingsStore.voiceInput,
      LucySettingsStore.aiRequests,
      LucySettingsStore.aiScreenSharing,
      LucySettingsStore.screenAutomation,
      LucySettingsStore.directPhoneActions,
      LucySettingsStore.memory,
      LucySettingsStore.voiceOutput,
      LucySettingsStore.autopilot,
    }.contains(key)) {
      await widget.controller.stopAgent();
    }
    if (!mounted) return;
    setState(() => _values[key] = enabled);
  }

  Future<void> _setNotifications(bool enabled) async {
    if (!enabled && widget.controller.isActive) {
      await widget.controller.stopAgent();
    }
    final saved = await _context.setNotificationContextEnabled(enabled);
    if (!saved) {
      _message('Could not update notification context.');
      return;
    }
    if (!enabled) {
      await _context.clearNotificationHistory();
    } else {
      await _context.openNotificationAccessSettings();
    }
    _message(enabled
        ? 'Review Android Notification access and enable Lucy if you want this context.'
        : 'Notification context disabled and its local history cleared.');
    if (mounted) setState(() => _contextStatus['notificationContextEnabled'] = enabled);
  }

  Future<void> _setLocation(bool enabled) async {
    if (!enabled && widget.controller.isActive) {
      await widget.controller.stopAgent();
    }
    final result = enabled
        ? await _context.enableApproximateLocation()
        : await _context.disableApproximateLocation();
    _message(result
        ? (enabled ? 'Approximate location enabled.' : 'Location context disabled.')
        : 'Location permission was not granted.');
    if (mounted) setState(() => _contextStatus['locationEnabled'] = enabled && result);
  }

  Future<void> _setCalendar(bool enabled) async {
    if (!enabled && widget.controller.isActive) {
      await widget.controller.stopAgent();
    }
    if (enabled) {
      final granted = await _context.requestCalendarAccess();
      if (!granted) {
        _message('Calendar permission was not granted.');
        return;
      }
    }
    final saved = await _context.setCalendarContextEnabled(enabled);
    if (!saved) {
      _message('Could not update calendar context.');
      return;
    }
    if (mounted) setState(() => _calendarEnabled = enabled);
  }

  Future<void> _setForegroundContext(bool enabled) async {
    if (!enabled && widget.controller.isActive) {
      await widget.controller.stopAgent();
    }
    await _settings.setEnabled(LucySettingsStore.foregroundAppContext, enabled);
    if (enabled) {
      await _context.openUsageAccessSettings();
      _message('Grant Usage access to Lucy in Android settings, then return here.');
    }
    if (mounted) setState(() => _foregroundContextEnabled = enabled);
  }

  Future<void> _setProactive(bool enabled) async {
    if (enabled) {
      final notificationPermission =
          await LucyRoutineScheduler.ensureNotificationPermission();
      if (!notificationPermission) {
        _message('Allow Lucy notifications, then enable proactive suggestions again.');
        return;
      }
    }
    final result = await _proactive.configure(
      enabled: enabled,
      quietStartHour: _proactiveStatus.quietStartHour,
      quietEndHour: _proactiveStatus.quietEndHour,
      dailyLimit: _proactiveStatus.dailyLimit,
      cooldownMinutes: _proactiveStatus.cooldownMinutes,
    );
    if (!result) {
      _message('Could not update proactive suggestions. Check notification permission.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _proactiveStatus = LucyProactiveStatus(
        enabled: enabled,
        quietStartHour: _proactiveStatus.quietStartHour,
        quietEndHour: _proactiveStatus.quietEndHour,
        dailyLimit: _proactiveStatus.dailyLimit,
        cooldownMinutes: _proactiveStatus.cooldownMinutes,
      );
    });
  }

  Future<void> _setQuietHour({required bool start, required int hour}) async {
    final startHour = start ? hour : _proactiveStatus.quietStartHour;
    final endHour = start ? _proactiveStatus.quietEndHour : hour;
    final result = await _proactive.configure(
      enabled: _proactiveStatus.enabled,
      quietStartHour: startHour,
      quietEndHour: endHour,
      dailyLimit: _proactiveStatus.dailyLimit,
      cooldownMinutes: _proactiveStatus.cooldownMinutes,
    );
    if (!result) {
      _message('Could not save quiet hours.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _proactiveStatus = LucyProactiveStatus(
        enabled: _proactiveStatus.enabled,
        quietStartHour: startHour,
        quietEndHour: endHour,
        dailyLimit: _proactiveStatus.dailyLimit,
        cooldownMinutes: _proactiveStatus.cooldownMinutes,
      );
    });
  }

  Future<void> _editWatcherExclusions() async {
    final editor = TextEditingController(
      text: _excludedWatcherPackages.join(String.fromCharCode(10)),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Exclude apps from popup handling'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: editor,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'com.example.bank',
              helperText: 'One Android package name per line. System permission screens and sensitive screens are always excluded.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) {
      editor.dispose();
      return;
    }
    final packages = editor.text
        .split(RegExp(r'\s+'))
        .map((value) => value.trim().toLowerCase())
        .where((value) => RegExp(r'^[a-z0-9_]+([.][a-z0-9_]+)+$').hasMatch(value))
        .toSet();
    editor.dispose();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'lucy_screen_watcher_excluded_packages',
      packages.toList()..sort(),
    );
    await _applyScreenWatcherSettings(_values, packages);
    if (mounted) setState(() => _excludedWatcherPackages = packages);
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value)),
    );
  }

  Future<void> _openPermissionGuide() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Lucy permissions guide'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Microphone', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Used only while you start voice listening.'),
              SizedBox(height: 10),
              Text('Accessibility', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Allows Lucy to inspect the visible UI tree and perform the screen actions you request.'),
              SizedBox(height: 10),
              Text('Screen capture', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Android asks each time a capture session starts. If AI screen sharing is enabled, the screenshot and UI text may be sent to the selected AI provider.'),
              SizedBox(height: 10),
              Text('Notification access', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Optional. Lucy keeps a bounded local notification cache. Short notification snippets may be included in AI requests when context is enabled.'),
              SizedBox(height: 10),
              Text('Calendar and approximate location', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Optional context sources. Upcoming event details or rounded location coordinates can be included in AI requests when enabled.'),
              SizedBox(height: 10),
              Text('Contacts and camera', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Requested only for the related phone action, such as contact lookup or camera/flashlight access.'),
              SizedBox(height: 10),
              Text('Internet', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Required for AI provider requests, updates and online features.'),
              SizedBox(height: 10),
              Text('Notifications and foreground services', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Used for Lucy’s visible stop control, voice session and scheduled reminders.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }


  String _setupText(String key) {
    const copy = <String, Map<String, String>>{
      'en': {
        'title': 'Set up Lucy',
        'intro': 'Enable only the capabilities you want. Android controls these permissions; Lucy cannot grant them silently.',
        'accessibility': 'Accessibility is required for screen reading and requested UI actions.',
        'open_accessibility': 'Open Accessibility settings',
        'capture': 'Screen capture is optional. Android displays its own consent prompt when a task needs screenshots.',
        'set_capture': 'Set up screen capture',
        'capture_ready': 'Screen capture is ready.',
        'capture_off': 'Screen capture was not enabled.',
        'notifications': 'Notification access is optional and is used only when notification context is enabled.',
        'open_notifications': 'Open notification access',
        'usage': 'Usage access is optional and adds the foreground app name to context.',
        'open_usage': 'Open Usage access',
        'calendar': 'Calendar access is optional and requested only for calendar context.',
        'set_calendar': 'Set up Calendar access',
        'calendar_ready': 'Calendar access is ready.',
        'calendar_off': 'Calendar access was not granted.',
        'mic_contacts': 'Microphone and Contacts permissions are requested only when you use the related feature. Never enable access you are uncomfortable with.',
        'finish': 'Finish',
      },
      'hi': {
        'title': 'लूसी सेटअप',
        'intro': 'केवल वही सुविधाएँ चालू करें जिनकी आपको ज़रूरत है। Android हर अनुमति आपसे पूछता है; लूसी उन्हें चुपचाप चालू नहीं कर सकती।',
        'accessibility': 'स्क्रीन पढ़ने और चुनी गई स्क्रीन कार्रवाइयों के लिए Accessibility ज़रूरी है।',
        'open_accessibility': 'Accessibility सेटिंग खोलें',
        'capture': 'Screen capture वैकल्पिक है। स्क्रीनशॉट की ज़रूरत होने पर Android अपनी अनुमति दिखाएगा।',
        'set_capture': 'Screen capture सेट करें',
        'capture_ready': 'Screen capture तैयार है।',
        'capture_off': 'Screen capture चालू नहीं हुआ।',
        'notifications': 'Notification access वैकल्पिक है और केवल Notification context चालू होने पर उपयोग होता है।',
        'open_notifications': 'Notification access खोलें',
        'usage': 'Usage access वैकल्पिक है और वर्तमान ऐप का नाम जोड़ता है।',
        'open_usage': 'Usage access खोलें',
        'calendar': 'Calendar access वैकल्पिक है और केवल Calendar context के लिए माँगा जाता है।',
        'set_calendar': 'Calendar access सेट करें',
        'calendar_ready': 'Calendar access तैयार है।',
        'calendar_off': 'Calendar access नहीं मिला।',
        'mic_contacts': 'Microphone और Contacts की अनुमति संबंधित सुविधा उपयोग करने पर ही माँगी जाएगी। केवल भरोसेमंद अनुमति दें।',
        'finish': 'पूरा करें',
      },
      'kn': {
        'title': 'ಲೂಸಿ ಸೆಟಪ್',
        'intro': 'ನಿಮಗೆ ಬೇಕಾದ ಸೌಲಭ್ಯಗಳನ್ನು ಮಾತ್ರ ಸಕ್ರಿಯಗೊಳಿಸಿ. ಅನುಮತಿಗಳನ್ನು Android ನಿಮ್ಮಿಂದಲೇ ಕೇಳುತ್ತದೆ; ಲೂಸಿ ಅವನ್ನು ಮೌನವಾಗಿ ನೀಡಲು ಸಾಧ್ಯವಿಲ್ಲ.',
        'accessibility': 'ಪರದೆಯನ್ನು ಓದಲು ಮತ್ತು ಆಯ್ದ UI ಕಾರ್ಯಗಳಿಗೆ Accessibility ಅಗತ್ಯ.',
        'open_accessibility': 'Accessibility ಸೆಟ್ಟಿಂಗ್ ತೆರೆಯಿರಿ',
        'capture': 'Screen capture ಐಚ್ಛಿಕ. ಸ್ಕ್ರೀನ್‌ಶಾಟ್ ಬೇಕಾದಾಗ Android ತನ್ನದೇ ಅನುಮತಿ ಕೇಳುತ್ತದೆ.',
        'set_capture': 'Screen capture ಹೊಂದಿಸಿ',
        'capture_ready': 'Screen capture ಸಿದ್ಧವಾಗಿದೆ.',
        'capture_off': 'Screen capture ಸಕ್ರಿಯವಾಗಿಲ್ಲ.',
        'notifications': 'Notification access ಐಚ್ಛಿಕ; Notification context ಸಕ್ರಿಯವಾಗಿದ್ದಾಗ ಮಾತ್ರ ಬಳಸಲಾಗುತ್ತದೆ.',
        'open_notifications': 'Notification access ತೆರೆಯಿರಿ',
        'usage': 'Usage access ಐಚ್ಛಿಕ; ಪ್ರಸ್ತುತ ಆಪ್ ಹೆಸರನ್ನು context ಗೆ ಸೇರಿಸುತ್ತದೆ.',
        'open_usage': 'Usage access ತೆರೆಯಿರಿ',
        'calendar': 'Calendar access ಐಚ್ಛಿಕ; Calendar context ಗಾಗಿ ಮಾತ್ರ ಕೇಳಲಾಗುತ್ತದೆ.',
        'set_calendar': 'Calendar access ಹೊಂದಿಸಿ',
        'calendar_ready': 'Calendar access ಸಿದ್ಧವಾಗಿದೆ.',
        'calendar_off': 'Calendar access ನೀಡಲಾಗಿಲ್ಲ.',
        'mic_contacts': 'Microphone ಮತ್ತು Contacts ಅನುಮತಿಗಳನ್ನು ಸಂಬಂಧಿತ ವೈಶಿಷ್ಟ್ಯ ಬಳಸುವಾಗ ಮಾತ್ರ ಕೇಳಲಾಗುತ್ತದೆ. ನಿಮಗೆ ಅಸೌಕರ್ಯವಿರುವ ಅನುಮತಿಯನ್ನು ನೀಡಬೇಡಿ.',
        'finish': 'ಮುಗಿಸಿ',
      },
      'ja': {
        'title': 'Lucyのセットアップ',
        'intro': '必要な機能だけを有効にしてください。権限はAndroidが確認し、Lucyが勝手に許可することはありません。',
        'accessibility': '画面の読み取りとUI操作にはユーザー補助が必要です。',
        'open_accessibility': 'ユーザー補助設定を開く',
        'capture': '画面キャプチャは任意です。スクリーンショットが必要なときAndroidが確認します。',
        'set_capture': '画面キャプチャを設定',
        'capture_ready': '画面キャプチャを利用できます。',
        'capture_off': '画面キャプチャは有効になっていません。',
        'notifications': '通知アクセスは任意で、通知コンテキストを有効にした場合のみ使用します。',
        'open_notifications': '通知アクセスを開く',
        'usage': '使用状況へのアクセスは任意で、現在のアプリ名を追加します。',
        'open_usage': '使用状況へのアクセスを開く',
        'calendar': 'カレンダーアクセスは任意で、カレンダーコンテキストにのみ使用します。',
        'set_calendar': 'カレンダーアクセスを設定',
        'calendar_ready': 'カレンダーにアクセスできます。',
        'calendar_off': 'カレンダーアクセスは許可されませんでした。',
        'mic_contacts': 'マイクと連絡先の権限は関連機能を使うときだけ要求されます。不安な権限は有効にしないでください。',
        'finish': '完了',
      },
      'ar': {
        'title': 'إعداد لوسي',
        'intro': 'فعّل الميزات التي تحتاجها فقط. أندرويد هو من يطلب الأذونات، ولا تستطيع لوسي منحها سرًا.',
        'accessibility': 'إمكانية الوصول مطلوبة لقراءة الشاشة وتنفيذ إجراءات الواجهة التي تطلبها.',
        'open_accessibility': 'فتح إعدادات إمكانية الوصول',
        'capture': 'التقاط الشاشة اختياري. سيعرض أندرويد طلب الموافقة عند الحاجة إلى لقطة شاشة.',
        'set_capture': 'إعداد التقاط الشاشة',
        'capture_ready': 'التقاط الشاشة جاهز.',
        'capture_off': 'لم يتم تفعيل التقاط الشاشة.',
        'notifications': 'الوصول إلى الإشعارات اختياري ويستخدم فقط عند تفعيل سياق الإشعارات.',
        'open_notifications': 'فتح الوصول إلى الإشعارات',
        'usage': 'الوصول إلى الاستخدام اختياري ويضيف اسم التطبيق الحالي إلى السياق.',
        'open_usage': 'فتح الوصول إلى الاستخدام',
        'calendar': 'الوصول إلى التقويم اختياري ويُطلب لسياق التقويم فقط.',
        'set_calendar': 'إعداد الوصول إلى التقويم',
        'calendar_ready': 'الوصول إلى التقويم جاهز.',
        'calendar_off': 'لم يتم منح الوصول إلى التقويم.',
        'mic_contacts': 'لا يُطلب إذن الميكروفون وجهات الاتصال إلا عند استخدام الميزة المرتبطة. لا تمنح إذنًا لا تشعر بالراحة تجاهه.',
        'finish': 'إنهاء',
      },
    };
    return copy[widget.controller.currentLang]?[key] ??
        copy['en']![key] ??
        key;
  }

  Future<void> _openSetupWizard({bool markSeen = false}) async {
    await widget.controller.speakSetupGuide();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_setupText('title')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_setupText('intro')),
              const SizedBox(height: 14),
              Text(_setupText('accessibility')),
              OutlinedButton.icon(
                onPressed: () async {
                  await widget.controller.screenCapture.openAccessibilitySettings();
                },
                icon: const Icon(Icons.accessibility_new),
                label: Text(_setupText('open_accessibility')),
              ),
              const SizedBox(height: 8),
              Text(_setupText('capture')),
              OutlinedButton.icon(
                onPressed: () async {
                  final granted = await widget.controller.screenCapture.requestPermission();
                  if (dialogContext.mounted) {
                    _message(
                      granted
                          ? _setupText('capture_ready')
                          : _setupText('capture_off'),
                    );
                  }
                },
                icon: const Icon(Icons.screen_share_outlined),
                label: Text(_setupText('set_capture')),
              ),
              const SizedBox(height: 8),
              Text(_setupText('notifications')),
              OutlinedButton.icon(
                onPressed: () async {
                  await _context.openNotificationAccessSettings();
                },
                icon: const Icon(Icons.notifications_outlined),
                label: Text(_setupText('open_notifications')),
              ),
              const SizedBox(height: 8),
              Text(_setupText('usage')),
              OutlinedButton.icon(
                onPressed: () async {
                  await _context.openUsageAccessSettings();
                },
                icon: const Icon(Icons.apps_outlined),
                label: Text(_setupText('open_usage')),
              ),
              const SizedBox(height: 8),
              Text(_setupText('calendar')),
              OutlinedButton.icon(
                onPressed: () async {
                  final granted = await _context.requestCalendarAccess();
                  _message(
                    granted
                        ? _setupText('calendar_ready')
                        : _setupText('calendar_off'),
                  );
                },
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(_setupText('set_calendar')),
              ),
              const SizedBox(height: 12),
              Text(_setupText('mic_contacts')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_setupText('finish')),
          ),
        ],
      ),
    );
    if (markSeen) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('lucy_setup_wizard_seen', true);
    }
  }

  Future<void> _showMemoryManager() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refreshDialog) {
          final memories = widget.controller.savedMemories;
          return AlertDialog(
            title: const Text('Saved memories'),
            content: SizedBox(
              width: 480,
              child: memories.isEmpty
                  ? const Text('Lucy has no saved memories.')
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 420),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: memories.length,
                        itemBuilder: (context, index) {
                          final memory = memories[index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(memory.text),
                            subtitle: Text(
                              '${memory.type} · ${memory.createdAt.toLocal().toString().split('.').first}',
                            ),
                            trailing: IconButton(
                              tooltip: 'Forget this memory',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await widget.controller.forgetUserMemoryById(memory.id);
                                refreshDialog(() {});
                              },
                            ),
                          );
                        },
                      ),
                    ),
            ),
            actions: [
              if (memories.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    await widget.controller.clearUserMemories();
                    refreshDialog(() {});
                  },
                  child: const Text('Clear all memories'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showLearningManager() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refreshDialog) {
          final maps = widget.controller.learnedUiMaps;
          final skills = widget.controller.learnedSkills;
          return AlertDialog(
            title: const Text('Learned layouts & skills'),
            content: SizedBox(
              width: 480,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 440),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Text('Screen layouts · ${maps.length}'),
                    if (maps.isEmpty) const ListTile(title: Text('No saved layouts')),
                    for (final map in maps.take(40))
                      ListTile(
                        dense: true,
                        title: Text(map['package']?.toString() ?? 'Unknown app'),
                        subtitle: Text('Signature: ${map['signature'] ?? 'unknown'}'),
                        trailing: IconButton(
                          tooltip: 'Forget this app layout',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final key = map['key']?.toString() ?? '';
                            if (key.isEmpty) return;
                            await widget.controller.forgetLearnedUiMap(key);
                            if (mounted) refreshDialog(() {});
                          },
                        ),
                      ),
                    const Divider(),
                    Text('Safe skills · ${skills.length}'),
                    if (skills.isEmpty) const ListTile(title: Text('No saved skills')),
                    for (final skill in skills.take(40))
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        secondary: IconButton(
                          tooltip: 'Forget this skill',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final id = skill['id']?.toString() ?? '';
                            if (id.isEmpty) return;
                            await widget.controller.forgetLearnedSkill(id);
                            if (mounted) refreshDialog(() {});
                          },
                        ),
                        title: Text(skill['command']?.toString() ?? 'Unnamed skill'),
                        subtitle: Text(
                          '${skill['package'] ?? 'Unknown app'} · successes: ${skill['successCount'] ?? 0} · failures: ${skill['failureCount'] ?? 0} · ${skill['approved'] == true ? 'approved' : 'approval required'}',
                        ),
                        value: skill['approved'] == true,
                        onChanged: ((skill['successCount'] as num?) ?? 0) < 2
                            ? null
                            : (approved) async {
                                final id = skill['id']?.toString() ?? '';
                                if (id.isEmpty) return;
                                await widget.controller.setLearnedSkillApproved(
                                  id,
                                  approved: approved,
                                );
                                if (mounted) refreshDialog(() {});
                              },
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              if (maps.isNotEmpty || skills.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (confirmContext) => AlertDialog(
                        title: const Text('Reset learned data?'),
                        content: const Text('This deletes all saved screen layouts and replayable skills on this device.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(confirmContext, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(confirmContext, true), child: const Text('Reset')),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await widget.controller.clearLearningData();
                      refreshDialog(() {});
                    }
                  },
                  child: const Text('Reset learned data'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_forever_outlined),
        title: const Text('Delete all Lucy data?'),
        content: const Text(
          'This removes saved memories, app preferences, activity history, cached notifications, scheduled reminders and all saved AI provider keys from this device. Android permissions already granted in system settings must be revoked there separately. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.controller.stopAgent();
      await widget.controller.clearUserMemories();
      await widget.controller.clearLearningData();
      await widget.controller.aiService.clearGeminiKey();
      widget.controller.aiService.resetChat();
      await _grok.clearApiKey();
      await _groq.clearApiKey();
      await _hms.clearApiKey();
      await _context.setNotificationContextEnabled(false);
      await _context.clearNotificationHistory();
      await _context.setCalendarContextEnabled(false);
      await _context.disableApproximateLocation();
      await _proactive.clearData();
      final routines = await LucyRoutineScheduler.listRoutines();
      for (final routine in routines) {
        final id = routine['id']?.toString();
        if (id != null && id.isNotEmpty) {
          await LucyRoutineScheduler.cancelReminder(id);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await _settings.setEnabled(LucySettingsStore.aiRequests, false);
      await _settings.setEnabled(LucySettingsStore.aiScreenSharing, false);
      await _settings.setEnabled(LucySettingsStore.providerFallback, false);
      await _settings.setEnabled(LucySettingsStore.memory, false);
      await _settings.setEnabled(LucySettingsStore.scheduledReminders, false);
      await _settings.setEnabled(LucySettingsStore.foregroundAppContext, false);
      widget.controller.clearConversation();
      if (!mounted) return;
      setState(() {
        _values = <String, bool>{
          ...LucySettingsStore.defaults,
          LucySettingsStore.aiRequests: false,
          LucySettingsStore.aiScreenSharing: false,
          LucySettingsStore.providerFallback: false,
          LucySettingsStore.memory: false,
          LucySettingsStore.scheduledReminders: false,
          LucySettingsStore.foregroundAppContext: false,
        };
        _proactiveStatus = const LucyProactiveStatus(
          enabled: false,
          quietStartHour: 22,
          quietEndHour: 8,
          dailyLimit: 3,
          cooldownMinutes: 120,
        );
      });
      _message('Lucy data and saved provider keys were deleted from this device.');
    } catch (error) {
      _message('Some data could not be cleared: ${error.runtimeType}. Review Android settings and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _capabilitySwitch({
    required String keyName,
    required String title,
    required String subtitle,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: _values[keyName] ?? LucySettingsStore.defaults[keyName] ?? false,
      onChanged: _busy ? null : (value) => _setCapability(keyName, value),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Capabilities', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _capabilitySwitch(
            keyName: LucySettingsStore.autopilot,
            title: 'Autopilot · low-risk actions',
            subtitle: 'When off, Lucy immediately stops the active task and blocks phone actions and learned-skill replay. Read-only time and battery queries remain available.',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.stop_circle_outlined),
            title: const Text('Emergency Stop control'),
            subtitle: const Text('Always on. Lucy keeps a Stop control in its active notification and app so you can interrupt a task immediately.'),
            value: _values[LucySettingsStore.safetyStop] ?? true,
            onChanged: null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.lock_outline),
            title: const Text('Review before sending or calling'),
            subtitle: const Text('Always required. Lucy may prepare a message or call, but you review the recipient and content before it is sent or placed.'),
            value: _values[LucySettingsStore.askBeforeSending] ?? true,
            onChanged: null,
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.aiRequests,
            title: 'Cloud AI requests',
            subtitle: 'Allow Lucy to send task text and enabled context to an external AI provider. Offline commands remain available.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.providerFallback,
            title: 'Provider fallback',
            subtitle: 'Allow the same task context to be sent to another configured provider if the selected provider fails.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.voiceInput,
            title: 'Voice input',
            subtitle: 'Allow Lucy to listen after you press the microphone control.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.voiceOutput,
            title: 'Spoken replies',
            subtitle: 'Allow Lucy to speak responses aloud.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.screenAutomation,
            title: 'Screen automation',
            subtitle: 'Allow Lucy to tap, type, swipe and navigate using Accessibility.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.aiScreenSharing,
            title: 'Share screen context with AI',
            subtitle: 'Allow screenshots and accessibility text to be sent to the selected vision provider.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.directPhoneActions,
            title: 'Direct phone actions',
            subtitle: 'Allow supported native actions such as alarms, navigation and device controls.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.memory,
            title: 'Saved memory',
            subtitle: 'Allow Lucy to use and save details you explicitly ask her to remember.',
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('View and manage saved memories'),
            subtitle: Text('${widget.controller.savedMemories.length} saved entries on this device'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _showMemoryManager,
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.scheduledReminders,
            title: 'Scheduled reminders',
            subtitle: 'Allow Lucy to schedule notification-only reminders.',
          ),
          const Divider(height: 28),
          Text('Learning & skills', style: Theme.of(context).textTheme.titleLarge),
          _capabilitySwitch(
            keyName: LucySettingsStore.uiMemory,
            title: 'Remember app layouts',
            subtitle: 'Store private screen maps, stable labels, resource IDs and normalized positions on this device.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.learnSkills,
            title: 'Learn safe workflows',
            subtitle: 'Lucy suggests a workflow only after two successful matching runs. You must approve it here before exact-screen replay is enabled. External or sensitive actions are never learned.',
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('View or reset learned layouts and skills'),
            subtitle: Text('${widget.controller.learnedUiMaps.length} layouts · ${widget.controller.learnedSkills.length} skills'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _showLearningManager,
          ),
          const Divider(height: 28),
          Text('Screen intelligence', style: Theme.of(context).textTheme.titleLarge),
          _capabilitySwitch(
            keyName: LucySettingsStore.screenWatcher,
            title: 'ScreenWatcher',
            subtitle: 'Monitor visible app changes and handle only recognized low-risk overlays.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.autoSkipAds,
            title: 'Skip exposed ads',
            subtitle: 'Tap only explicit Skip Ad controls exposed in the accessibility tree.',
          ),
          _capabilitySwitch(
            keyName: LucySettingsStore.autoDismissPopups,
            title: 'Dismiss safe popups',
            subtitle: 'Dismiss exact safe labels such as Not now, Maybe later, No thanks and Got it. Permission and sensitive dialogs stay manual.',
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Per-app exclusions'),
            subtitle: Text(
              _excludedWatcherPackages.isEmpty
                  ? 'No additional app exclusions'
                  : _excludedWatcherPackages.join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _busy ? null : _editWatcherExclusions,
          ),
          const Divider(height: 28),
          Text('Context sources', style: Theme.of(context).textTheme.titleLarge),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notification context'),
            subtitle: const Text('Keep a small local cache and optionally include short snippets in AI requests.'),
            value: _contextStatus['notificationContextEnabled'] == true,
            onChanged: _busy ? null : _setNotifications,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Foreground app context'),
            subtitle: const Text('Include the current app name when Usage access is granted.'),
            value: _foregroundContextEnabled,
            onChanged: _busy ? null : _setForegroundContext,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Calendar context'),
            subtitle: const Text('Include upcoming event details in AI context only when enabled.'),
            value: _calendarEnabled,
            onChanged: _busy ? null : _setCalendar,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Approximate location'),
            subtitle: const Text('Include rounded coordinates in AI context when permission is granted.'),
            value: _contextStatus['locationEnabled'] == true,
            onChanged: _busy ? null : _setLocation,
          ),
          const Divider(height: 28),
          Text('Proactive suggestions', style: Theme.of(context).textTheme.titleLarge),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable proactive suggestions'),
            subtitle: const Text('Local battery/calendar checks. Suggestions are notifications only; Lucy does not perform actions in the background.'),
            value: _proactiveStatus.enabled,
            onChanged: _busy ? null : _setProactive,
          ),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _proactiveStatus.quietStartHour,
                  decoration: const InputDecoration(labelText: 'Quiet from'),
                  items: List.generate(24, (hour) => DropdownMenuItem(
                    value: hour,
                    child: Text('${hour.toString().padLeft(2, '0')}:00'),
                  )),
                  onChanged: _busy ? null : (value) {
                    if (value != null) _setQuietHour(start: true, hour: value);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _proactiveStatus.quietEndHour,
                  decoration: const InputDecoration(labelText: 'Quiet until'),
                  items: List.generate(24, (hour) => DropdownMenuItem(
                    value: hour,
                    child: Text('${hour.toString().padLeft(2, '0')}:00'),
                  )),
                  onChanged: _busy ? null : (value) {
                    if (value != null) _setQuietHour(start: false, hour: value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _openSetupWizard(),
            icon: const Icon(Icons.tune),
            label: const Text('Open setup wizard'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openPermissionGuide,
            icon: const Icon(Icons.privacy_tip_outlined),
            label: const Text('Permissions guide & data sharing'),
          ),
          const SizedBox(height: 12),
          Text(
            'What can be sent to an AI provider? Your command, the current accessibility UI text, the screenshot when enabled, a small relevant set of memories when enabled, and opted-in context such as short notification snippets, upcoming calendar events or rounded approximate coordinates. Gemini, Groq and Grok can receive images; 100milionseek is text-only. Provider fallback can send the same task context to another configured provider. API keys are stored in Android secure storage.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _deleteAllData,
            icon: const Icon(Icons.delete_forever),
            label: Text(_busy ? 'Deleting…' : 'Delete all my data'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
