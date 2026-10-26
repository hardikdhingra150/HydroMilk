import 'package:flutter/material.dart';
import 'reminders.dart';

class ReminderSettingsPage extends StatefulWidget {
  const ReminderSettingsPage({super.key, required this.controller});
  final ReminderController controller;

  @override
  State<ReminderSettingsPage> createState() => _ReminderSettingsPageState();
}

class _ReminderSettingsPageState extends State<ReminderSettingsPage>
    with WidgetsBindingObserver {
  ReminderController get reminders => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Re-check permissions when opening settings, without prompting.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reminders.refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) reminders.refresh();
  }

  String timeLabel(int minute) =>
      TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context);

  Future<void> pickTime({required bool monthly}) async {
    final settings = reminders.settings;
    final minute = monthly ? settings.monthlyMinute : settings.dailyMinute;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
      helpText: monthly
          ? 'Monthly bill reminder time'
          : 'Daily entry reminder time',
    );
    if (time == null || !mounted) return;
    final nextMinute = time.hour * 60 + time.minute;
    // Read current settings after the picker closes, in case permissions changed.
    await reminders.save(
      monthly
          ? reminders.settings.copyWith(monthlyMinute: nextMinute)
          : reminders.settings.copyWith(dailyMinute: nextMinute),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: reminders,
    builder: (context, _) {
      final settings = reminders.settings;
      final enabled = reminders.supported && !reminders.busy;
      return Scaffold(
        appBar: AppBar(title: const Text('Reminders')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const Icon(Icons.notifications_active_outlined, size: 46),
              const SizedBox(height: 12),
              Text(
                'A little nudge, at your time',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Choose reminders for this phone. Each family member can set their own times. They work without internet.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (!reminders.supported)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Reminders are available in the Android app.'),
                  ),
                ),
              if (reminders.busy) const LinearProgressIndicator(),
              if (reminders.error != null ||
                  (reminders.permissionGranted == false &&
                      (settings.daily || settings.monthly)))
                Card(
                  color: const Color(0xFFFFEADC),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          reminders.error ??
                              'Notifications are blocked in Android settings. Your reminder choices are saved. Allow notifications to receive them.',
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          children: [
                            TextButton(
                              onPressed: enabled
                                  ? reminders.openSettings
                                  : null,
                              child: const Text('Android settings'),
                            ),
                            TextButton(
                              onPressed: enabled ? reminders.refresh : null,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('daily-reminder'),
                      title: const Text(
                        'Daily entry reminder',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        'Remember today’s milk and water deliveries.',
                      ),
                      value: settings.daily,
                      onChanged: enabled
                          ? (value) =>
                                reminders.save(settings.copyWith(daily: value))
                          : null,
                    ),
                    ListTile(
                      key: const ValueKey('daily-reminder-time'),
                      leading: const Icon(Icons.schedule),
                      title: const Text('Every day, around'),
                      subtitle: Text(
                        timeLabel(settings.dailyMinute),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: enabled ? () => pickTime(monthly: false) : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('monthly-reminder'),
                      title: const Text(
                        'Monthly bill review',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        'On the 1st, review last month’s bills and payments.',
                      ),
                      value: settings.monthly,
                      onChanged: enabled
                          ? (value) => reminders.save(
                              settings.copyWith(monthly: value),
                            )
                          : null,
                    ),
                    ListTile(
                      key: const ValueKey('monthly-reminder-time'),
                      leading: const Icon(Icons.event_repeat),
                      title: const Text('1st of each month, around'),
                      subtitle: Text(
                        timeLabel(settings.monthlyMinute),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: enabled ? () => pickTime(monthly: true) : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                key: const ValueKey('test-reminder'),
                onPressed: enabled
                    ? () async {
                        final sent = await reminders.test();
                        if (sent && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Test sent. Check your phone’s notification tray.',
                              ),
                            ),
                          );
                        }
                      }
                    : null,
                icon: const Icon(Icons.notifications_outlined),
                label: const Text('Send a test notification'),
              ),
              TextButton(
                onPressed: enabled ? reminders.openSettings : null,
                child: const Text('Android notification settings'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Times follow this phone’s time zone when you open the app. Android may deliver reminders a little later to save battery. Force-stopping the app or restricting its background activity can pause reminders; reopen HydraMilk afterwards.',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      );
    },
  );
}
