import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_aware_ai/services/lucy_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('capabilities default to enabled for existing installations', () async {
    final settings = LucySettingsStore();
    final values = await settings.readAll();

    expect(values[LucySettingsStore.voiceInput], isTrue);
    expect(values[LucySettingsStore.voiceOutput], isTrue);
    expect(values[LucySettingsStore.screenAutomation], isTrue);
    expect(values[LucySettingsStore.aiScreenSharing], isTrue);
    expect(values[LucySettingsStore.directPhoneActions], isTrue);
    expect(values[LucySettingsStore.memory], isTrue);
    expect(values[LucySettingsStore.scheduledReminders], isTrue);
    expect(values[LucySettingsStore.aiRequests], isTrue);
    expect(values[LucySettingsStore.providerFallback], isTrue);
    expect(values[LucySettingsStore.foregroundAppContext], isTrue);
  });

  test('capability changes persist between store instances', () async {
    final first = LucySettingsStore();
    await first.setEnabled(LucySettingsStore.aiScreenSharing, false);
    await first.setEnabled(LucySettingsStore.directPhoneActions, false);

    final second = LucySettingsStore();
    expect(await second.isEnabled(LucySettingsStore.aiScreenSharing), isFalse);
    expect(await second.isEnabled(LucySettingsStore.directPhoneActions), isFalse);
    expect(await second.isEnabled(LucySettingsStore.memory), isTrue);
  });

  test('autopilot defaults on and mandatory safety controls cannot be disabled', () async {
    final settings = LucySettingsStore();
    final values = await settings.readAll();

    expect(values[LucySettingsStore.autopilot], isTrue);
    expect(values[LucySettingsStore.safetyStop], isTrue);
    expect(values[LucySettingsStore.askBeforeSending], isTrue);
    expect(
      () => settings.setEnabled(LucySettingsStore.safetyStop, false),
      throwsStateError,
    );
    expect(
      () => settings.setEnabled(LucySettingsStore.askBeforeSending, false),
      throwsStateError,
    );
  });

  test('unknown capability keys are rejected', () async {
    expect(
      () => LucySettingsStore().setEnabled('not_a_real_capability', true),
      throwsArgumentError,
    );
  });
}
