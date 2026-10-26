import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:peach_ledger/main.dart';
import 'package:peach_ledger/reminders.dart';
import 'package:peach_ledger/store.dart';
import 'app_test.dart' show capture;

class FakeReminders implements ReminderBackend {
  bool granted = true, failApply = false, failInitialize = false;
  @override
  bool supported = true;
  int requests = 0, tests = 0, opens = 0;
  String? launch;
  void Function(String?)? tap;
  final List<ReminderPreferences> applied = [];
  @override
  Future<String?> initialize(void Function(String?) onTap) async {
    if (failInitialize) throw StateError('Plugin failed');
    tap = onTap;
    return launch;
  }

  @override
  Future<bool> allowed() async => granted;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return granted;
  }

  @override
  Future<void> apply(ReminderPreferences settings) async {
    if (failApply) throw StateError('Scheduling failed');
    applied.add(settings);
  }

  @override
  Future<void> test() async {
    tests++;
  }

  @override
  Future<void> openSettings() async {
    opens++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    for (final family in ['DMSans', 'Fraunces', 'MaterialIcons']) {
      final loader = FontLoader(family)
        ..addFont(
          rootBundle.load(
            family == 'MaterialIcons'
                ? 'fonts/MaterialIcons-Regular.otf'
                : 'assets/fonts/$family.ttf',
          ),
        );
      await loader.load();
    }
  });

  test(
    'Fresh or malformed settings have no enabled reminders; invalid times are safe',
    () {
      for (final raw in [null, 'broken', '[]', '{}']) {
        final settings = ReminderPreferences.read(raw);
        expect(settings.daily, false);
        expect(settings.monthly, false);
        expect(settings.dailyMinute, 1200);
      }
      final settings = ReminderPreferences.read(
        '{"daily":true,"monthly":"true","dailyMinute":1440,"monthlyMinute":-1}',
      );
      expect(settings.daily, true);
      expect(settings.monthly, false);
      expect(settings.dailyMinute, 1200);
      expect(settings.monthlyMinute, 540);
      expect(ReminderPreferences.read(settings.encode()).daily, true);
    },
  );

  test(
    'Daily scheduling rolls dates and years, including exactly at chosen time',
    () {
      final zone = tz.getLocation('Asia/Kolkata');
      expect(
        nextReminder(tz.TZDateTime(zone, 2026, 12, 31, 19), 1200),
        tz.TZDateTime(zone, 2026, 12, 31, 20),
      );
      expect(
        nextReminder(tz.TZDateTime(zone, 2026, 12, 31, 20), 1200),
        tz.TZDateTime(zone, 2027, 1, 1, 20),
      );
      expect(
        nextReminder(tz.TZDateTime(zone, 2028, 2, 28, 23), 60),
        tz.TZDateTime(zone, 2028, 2, 29, 1),
      );
    },
  );

  test(
    'Monthly review is the next first day, including leap February and January',
    () {
      final zone = tz.getLocation('Asia/Kolkata');
      for (final item in [
        [
          tz.TZDateTime(zone, 2028, 2, 29, 23),
          tz.TZDateTime(zone, 2028, 3, 1, 9),
        ],
        [tz.TZDateTime(zone, 2026, 12, 31), tz.TZDateTime(zone, 2027, 1, 1, 9)],
        [
          tz.TZDateTime(zone, 2027, 1, 1, 8),
          tz.TZDateTime(zone, 2027, 1, 1, 9),
        ],
        [
          tz.TZDateTime(zone, 2027, 1, 1, 9),
          tz.TZDateTime(zone, 2027, 2, 1, 9),
        ],
      ]) {
        expect(nextReminder(item[0], 540, monthly: true), item[1]);
      }
    },
  );

  test('DST keeps the selected wall-clock time instead of adding 24 hours', () {
    final zone = tz.getLocation('America/New_York');
    final before = tz.TZDateTime(zone, 2026, 3, 7, 20);
    final next = nextReminder(before, 1200);
    expect(next, tz.TZDateTime(zone, 2026, 3, 8, 20));
    expect(next.difference(before), const Duration(hours: 23));
    final fall = tz.TZDateTime(zone, 2026, 10, 31, 20);
    expect(
      nextReminder(fall, 1200).difference(fall),
      const Duration(hours: 25),
    );
  });

  test('A spring-forward gap cannot permanently change the recurring hour', () {
    final zone = tz.getLocation('America/New_York');
    final now = tz.TZDateTime(zone, 2026, 3, 8, 1);
    final anchor = nextReminder(now, 150);
    expect(anchor.hour, 2);
    expect(anchor.minute, 30);
    expect(anchor, tz.TZDateTime(zone, 2026, 3, 9, 2, 30));
  });

  test(
    'Opt-in, custom times and opt-out survive restarts; initialization never prompts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final backend = FakeReminders();
      final controller = ReminderController(prefs, backend);
      await controller.initialize();
      expect(backend.requests, 0);
      expect(backend.applied.last.daily, false);
      expect(
        await controller.save(
          const ReminderPreferences(
            daily: true,
            dailyMinute: 1145,
            monthly: true,
            monthlyMinute: 630,
          ),
        ),
        true,
      );
      expect(backend.requests, 1);
      final reopened = ReminderController(prefs, backend);
      await reopened.initialize();
      expect(backend.requests, 1);
      expect(reopened.settings.dailyMinute, 1145);
      expect(backend.applied.last.monthlyMinute, 630);
      await reopened.save(
        reopened.settings.copyWith(daily: false, monthly: false),
      );
      expect(backend.applied.last.daily, false);
      expect(backend.applied.last.monthly, false);
      expect(
        ReminderPreferences.read(
          prefs.getString(ReminderController.storageKey),
        ).daily,
        false,
      );
      controller.dispose();
      reopened.dispose();
    },
  );

  test(
    'Denied permission does not enable reminders or falsely report a sent test',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = FakeReminders()..granted = false;
      final controller = ReminderController(
        await SharedPreferences.getInstance(),
        backend,
      );
      await controller.initialize();
      expect(
        await controller.save(const ReminderPreferences(daily: true)),
        false,
      );
      expect(controller.settings.daily, false);
      expect(controller.error, contains('blocked'));
      expect(await controller.test(), false);
      expect(backend.tests, 0);
      await controller.openSettings();
      expect(backend.opens, 1);
      backend.granted = true;
      expect(
        await controller.save(const ReminderPreferences(daily: true)),
        true,
      );
      controller.dispose();
    },
  );

  test(
    'Permission revocation cancels scheduled reminders but preserves choices for recovery',
    () async {
      SharedPreferences.setMockInitialValues({
        ReminderController.storageKey: const ReminderPreferences(
          daily: true,
          monthly: true,
        ).encode(),
      });
      final backend = FakeReminders();
      final controller = ReminderController(
        await SharedPreferences.getInstance(),
        backend,
      );
      await controller.initialize();
      backend.granted = false;
      await controller.refresh();
      expect(backend.applied.last.daily, false);
      expect(backend.applied.last.monthly, false);
      expect(controller.settings.daily, true);
      backend.granted = true;
      await controller.refresh();
      expect(backend.applied.last.daily, true);
      expect(backend.applied.last.monthly, true);
      expect(backend.requests, 0);
      controller.dispose();
    },
  );

  test(
    'Startup and schedule failures recover without losing saved reminder choices',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = FakeReminders()..failInitialize = true;
      final controller = ReminderController(
        await SharedPreferences.getInstance(),
        backend,
      );
      await controller.initialize();
      expect(controller.ready, false);
      expect(controller.error, isNotNull);
      backend.failInitialize = false;
      backend.failApply = true;
      expect(
        await controller.save(const ReminderPreferences(daily: true)),
        false,
      );
      expect(controller.settings.daily, true);
      expect(controller.error, isNotNull);
      backend.failApply = false;
      await controller.refresh();
      expect(controller.error, isNull);
      expect(backend.applied.last.daily, true);
      controller.dispose();
    },
  );

  test(
    'Real Android plugin receives recurring local-zone schedules, safe IDs and cancellation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      const zoneChannel = MethodChannel('flutter_timezone');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'initialize' ||
          'areNotificationsEnabled' ||
          'requestNotificationsPermission' ||
          'openAppNotificationSettings' => true,
          'getNotificationAppLaunchDetails' => {
            'notificationLaunchedApp': true,
            'notificationResponse': {
              'payload': 'bills',
              'notificationResponseType': 0,
            },
          },
          'getNotificationChannels' => [],
          _ => null,
        };
      });
      messenger.setMockMethodCallHandler(
        zoneChannel,
        (_) async => 'Asia/Kolkata',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(zoneChannel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      final backend = AndroidReminderBackend();
      expect(await backend.initialize((_) {}), 'bills');
      expect(await backend.requestPermission(), true);
      await backend.apply(
        const ReminderPreferences(daily: true, monthly: true),
      );
      final scheduled = calls
          .where((c) => c.method == 'zonedSchedule')
          .toList();
      expect(scheduled, hasLength(2));
      for (final call in scheduled) {
        final args = call.arguments as Map;
        expect(args['timeZoneName'], 'Asia/Kolkata');
        expect(
          args['platformSpecifics']['scheduleMode'],
          'inexactAllowWhileIdle',
        );
        expect(args['platformSpecifics']['icon'], 'ic_stat_drop');
      }
      expect((scheduled[0].arguments as Map)['payload'], 'entries');
      expect(
        (scheduled[0].arguments as Map)['matchDateTimeComponents'],
        DateTimeComponents.time.index,
      );
      expect((scheduled[1].arguments as Map)['payload'], 'bills');
      expect(
        (scheduled[1].arguments as Map)['matchDateTimeComponents'],
        DateTimeComponents.dayOfMonthAndTime.index,
      );
      await backend.test();
      expect(
        (calls.last.arguments as Map)['id'],
        AndroidReminderBackend.testId,
      );
      await backend.apply(const ReminderPreferences());
      expect(
        calls
            .where((c) => c.method == 'cancel')
            .map((c) => (c.arguments as Map)['id']),
        containsAll([
          AndroidReminderBackend.dailyId,
          AndroidReminderBackend.monthlyId,
        ]),
      );
    },
  );

  for (final scale in [1.0, 1.4]) {
    testWidgets('Reminder settings opt-in and test at 320px / text $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
      addTearDown(tester.platformDispatcher.clearAlwaysUse24HourTestValue);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LedgerStore(prefs);
      await store.load();
      await store.chooseLocalMode();
      store.familyId = 'layout-test-family';
      final backend = FakeReminders();
      final reminders = ReminderController(prefs, backend);
      await reminders.initialize();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LedgerApp(store: store, reminders: reminders),
        ),
      );
      await tester.tap(find.byTooltip('Reminders'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('daily-reminder')));
      await tester.pumpAndSettle();
      expect(reminders.settings.daily, true);
      await tester.ensureVisible(
        find.byKey(const ValueKey('monthly-reminder')),
      );
      await tester.tap(find.byKey(const ValueKey('monthly-reminder')));
      await tester.pumpAndSettle();
      expect(reminders.settings.monthly, true);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('daily-reminder-time')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('daily-reminder-time')));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Switch to text input mode'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '19');
      await tester.enterText(find.byType(TextField).at(1), '45');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(reminders.settings.dailyMinute, 1185);
      await tester.ensureVisible(find.byKey(const ValueKey('test-reminder')));
      await tester.tap(find.byKey(const ValueKey('test-reminder')));
      await tester.pumpAndSettle();
      expect(backend.tests, 1);
      expect(find.textContaining('Test sent.'), findsOneWidget);
      if (scale == 1) {
        await tester.drag(find.byType(ListView).last, const Offset(0, 2000));
        await tester.pumpAndSettle();
        await capture(tester, key, 'HydraMilk-reminders');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      reminders.dispose();
      store.dispose();
    });
  }

  testWidgets('Denied notifications show recovery and no false test success', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LedgerStore(prefs);
    await store.load();
    await store.chooseLocalMode();
    final backend = FakeReminders()..granted = false;
    final reminders = ReminderController(prefs, backend);
    await reminders.initialize();
    await tester.pumpWidget(LedgerApp(store: store, reminders: reminders));
    await tester.tap(find.byTooltip('Reminders'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('test-reminder')));
    await tester.tap(find.byKey(const ValueKey('test-reminder')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Notifications are blocked.'), findsOneWidget);
    expect(find.textContaining('Test sent.'), findsNothing);
    expect(reminders.settings.daily, false);
    await tester.pumpWidget(const SizedBox());
    reminders.dispose();
    store.dispose();
  });

  testWidgets(
    'Cold and warm reminder taps open the right billing month and current register',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LedgerStore(prefs);
      await store.load();
      final backend = FakeReminders()..launch = 'bills';
      final reminders = ReminderController(prefs, backend);
      await reminders.initialize();
      await tester.pumpWidget(LedgerApp(store: store, reminders: reminders));
      expect(reminders.pendingTarget, ReminderTarget.bills);
      await store.chooseLocalMode();
      await tester.pumpAndSettle();
      final now = DateTime.now();
      expect(
        find.text(
          DateFormat('MMMM yyyy').format(DateTime(now.year, now.month - 1)),
        ),
        findsWidgets,
      );
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      await tester.tap(find.byTooltip('Reminders'));
      await tester.pumpAndSettle();
      expect(find.text('A little nudge, at your time'), findsOneWidget);
      backend.tap!('entries');
      await tester.pumpAndSettle();
      expect(find.text('A little nudge, at your time'), findsNothing);
      expect(find.text(DateFormat('MMMM yyyy').format(now)), findsWidgets);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(reminders.pendingTarget, isNull);
      backend.tap!('unknown');
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      reminders.dispose();
      store.dispose();
    },
  );
}
