import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

enum ReminderTarget { entries, bills }

class ReminderPreferences {
  const ReminderPreferences({
    this.daily = false,
    this.dailyMinute = 20 * 60,
    this.monthly = false,
    this.monthlyMinute = 9 * 60,
  });

  final bool daily, monthly;
  final int dailyMinute, monthlyMinute;

  factory ReminderPreferences.read(String? raw) {
    try {
      final map = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      int minute(String key, int fallback) {
        final value = map[key];
        return value is int && value >= 0 && value < 1440 ? value : fallback;
      }

      return ReminderPreferences(
        daily: map['daily'] == true,
        monthly: map['monthly'] == true,
        dailyMinute: minute('dailyMinute', 1200),
        monthlyMinute: minute('monthlyMinute', 540),
      );
    } catch (_) {
      return const ReminderPreferences();
    }
  }

  ReminderPreferences copyWith({
    bool? daily,
    bool? monthly,
    int? dailyMinute,
    int? monthlyMinute,
  }) => ReminderPreferences(
    daily: daily ?? this.daily,
    monthly: monthly ?? this.monthly,
    dailyMinute: dailyMinute ?? this.dailyMinute,
    monthlyMinute: monthlyMinute ?? this.monthlyMinute,
  );

  String encode() => jsonEncode({
    'daily': daily,
    'monthly': monthly,
    'dailyMinute': dailyMinute,
    'monthlyMinute': monthlyMinute,
  });
}

// A future calendar anchor for the plugin's recurring time/day matcher. Avoid
// anchoring to a DST gap's normalized hour, which would shift later reminders.
tz.TZDateTime nextReminder(
  tz.TZDateTime now,
  int minute, {
  bool monthly = false,
}) {
  RangeError.checkValueInInterval(minute, 0, 1439, 'minute');
  var date = DateTime.utc(now.year, now.month, monthly ? 1 : now.day);
  while (true) {
    final result = tz.TZDateTime(
      now.location,
      date.year,
      date.month,
      date.day,
      minute ~/ 60,
      minute % 60,
    );
    if (result.isAfter(now) &&
        result.day == date.day &&
        result.hour == minute ~/ 60 &&
        result.minute == minute % 60) {
      return result;
    }
    date = DateTime.utc(
      date.year,
      date.month + (monthly ? 1 : 0),
      monthly ? 1 : date.day + 1,
    );
  }
}

abstract class ReminderBackend {
  bool get supported;
  Future<String?> initialize(void Function(String?) onTap);
  Future<bool> allowed();
  Future<bool> requestPermission();
  Future<void> apply(ReminderPreferences settings);
  Future<void> test();
  Future<void> openSettings();
}

class AndroidReminderBackend implements ReminderBackend {
  AndroidReminderBackend({FlutterLocalNotificationsPlugin? plugin})
    : plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin plugin;
  static const dailyId = 1101, monthlyId = 1102, testId = 1103;
  static const channelId = 'hydramilk_reminders_v1';
  static const details = NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      'Milk & water reminders',
      channelDescription: 'Daily entries and monthly bill reviews',
      icon: 'ic_stat_drop',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.private,
    ),
  );

  AndroidFlutterLocalNotificationsPlugin get android => plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()!;

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<String?> initialize(void Function(String?) onTap) async {
    tzdata.initializeTimeZones();
    final initialized = await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_drop'),
      ),
      onDidReceiveNotificationResponse: (response) => onTap(response.payload),
    );
    if (initialized != true) throw StateError('Notifications unavailable');
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        'Milk & water reminders',
        description: 'Daily entries and monthly bill reviews',
        importance: Importance.defaultImportance,
      ),
    );
    final launch = await plugin.getNotificationAppLaunchDetails();
    return launch?.didNotificationLaunchApp == true
        ? launch?.notificationResponse?.payload
        : null;
  }

  @override
  Future<bool> allowed() async {
    if (await android.areNotificationsEnabled() != true) return false;
    final channels = await android.getNotificationChannels();
    return !(channels ?? []).any(
      (c) => c.id == channelId && c.importance == Importance.none,
    );
  }

  @override
  Future<bool> requestPermission() async {
    await android.requestNotificationsPermission();
    return allowed();
  }

  @override
  Future<void> apply(ReminderPreferences settings) async {
    // Cancel disabled reminders even when the notification permission is denied.
    if (!settings.daily) await plugin.cancel(id: dailyId);
    if (!settings.monthly) await plugin.cancel(id: monthlyId);
    if (!settings.daily && !settings.monthly) return;
    final zone = await FlutterTimezone.getLocalTimezone();
    final location = tz.getLocation(zone.identifier);
    final now = tz.TZDateTime.now(location);
    if (settings.daily) {
      await plugin.zonedSchedule(
        id: dailyId,
        title: 'A little update for today',
        body: 'Record today’s milk and water deliveries in HydraMilk.',
        scheduledDate: nextReminder(now, settings.dailyMinute),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: ReminderTarget.entries.name,
      );
    }
    if (settings.monthly) {
      await plugin.zonedSchedule(
        id: monthlyId,
        title: 'Your monthly bill check',
        body:
            'Review last month’s milk and water bills. Record any payments you made.',
        scheduledDate: nextReminder(now, settings.monthlyMinute, monthly: true),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
        payload: ReminderTarget.bills.name,
      );
    }
  }

  @override
  Future<void> test() => plugin.show(
    id: testId,
    title: 'HydraMilk reminders are ready',
    body: 'Tap to open your milk and water register.',
    notificationDetails: details,
    payload: ReminderTarget.entries.name,
  );

  @override
  Future<void> openSettings() async {
    if (await android.openAppNotificationSettings() != true) {
      throw StateError('Could not open settings');
    }
  }
}

class ReminderController extends ChangeNotifier {
  ReminderController(this.prefs, this.backend);
  static const storageKey = 'hydramilk_reminders_v1';
  final SharedPreferences prefs;
  final ReminderBackend backend;
  ReminderPreferences settings = const ReminderPreferences();
  ReminderTarget? pendingTarget;
  bool busy = false, ready = false;
  bool? permissionGranted;
  String? error;
  bool get supported => backend.supported;

  Future<void> initialize() async {
    settings = ReminderPreferences.read(prefs.getString(storageKey));
    await refresh();
  }

  void _onTap(String? payload) {
    if (payload == ReminderTarget.entries.name) {
      pendingTarget = ReminderTarget.entries;
    }
    if (payload == ReminderTarget.bills.name) {
      pendingTarget = ReminderTarget.bills;
    }
    notifyListeners();
  }

  Future<void> _ensureReady() async {
    if (!ready) {
      final payload = await backend.initialize(_onTap);
      ready = true;
      if (payload != null) _onTap(payload);
    }
  }

  Future<void> _sync() async {
    permissionGranted = await backend.allowed();
    await backend.apply(
      permissionGranted == true
          ? settings
          : settings.copyWith(daily: false, monthly: false),
    );
  }

  Future<bool> _run(Future<void> Function() task) async {
    if (busy || !supported) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _ensureReady();
      await task();
      return error == null;
    } catch (_) {
      error =
          'Could not update reminders. Tap Retry, or check Android notification settings.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    await _run(_sync);
  }

  Future<bool> save(ReminderPreferences next) => _run(() async {
    if ((next.daily && !settings.daily) ||
        (next.monthly && !settings.monthly)) {
      permissionGranted = await backend.requestPermission();
      if (permissionGranted != true) {
        error =
            'Notifications are blocked. Allow Milk & water reminders in Android settings, then turn the reminder on again.';
        return;
      }
    }
    if (!await prefs.setString(storageKey, next.encode())) {
      throw StateError('Preferences not saved');
    }
    settings = next;
    await _sync();
  });

  Future<bool> test() => _run(() async {
    permissionGranted = await backend.requestPermission();
    if (permissionGranted != true) {
      error =
          'Notifications are blocked. Allow Milk & water reminders in Android settings first.';
      return;
    }
    await backend.test();
  });

  Future<void> openSettings() async {
    await _run(backend.openSettings);
  }
}
