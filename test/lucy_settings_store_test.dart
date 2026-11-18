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

  test('autopilot defaults on and can be disabled independently', () async {
    final settings = LucySettingsStore();

    expect(await settings.isEnabled(LucySettingsStore.autopilot), isTrue);
    await settings.setEnabled(LucySettingsStore.autopilot, false);
    expect(await settings.isEnabled(LucySettingsStore.autopilot), isFalse);
  });

  test('mandatory safety controls cannot be disabled', () async {
    final settings = LucySettingsStore();
    final values = await settings.readAll();

    expect(values[LucySettingsStore.safetyStop], isTrue);
    expect(values[LucySettingsStore.askBeforeSending], isTrue);
    await expectLater(
      settings.setEnabled(LucySettingsStore.safetyStop, false),
      throwsStateError,
    );
    await expectLater(
      settings.setEnabled(LucySettingsStore.askBeforeSending, false),
      throwsStateError,
    );
  });

  test('mandatory safety controls stay enabled even if stored values are false', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      LucySettingsStore.safetyStop: false,
      LucySettingsStore.askBeforeSending: false,
    });
    final settings = LucySettingsStore();

    expect(await settings.isEnabled(LucySettingsStore.safetyStop), isTrue);
    expect(await settings.isEnabled(LucySettingsStore.askBeforeSending), isTrue);
    final values = await settings.readAll();
    expect(values[LucySettingsStore.safetyStop], isTrue);
    expect(values[LucySettingsStore.askBeforeSending], isTrue);
  });

  test('unknown capability keys are rejected', () async {
    expect(
      () => LucySettingsStore().setEnabled('not_a_real_capability', true),
      throwsArgumentError,
    );
  });
}
