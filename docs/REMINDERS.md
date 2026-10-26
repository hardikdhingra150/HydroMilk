# HydraMilk reminders

## Enable on your phone

1. Install `HydraMilk-v3.1.apk` over the earlier supplied APK. Keep the app installed to preserve local records; export important data before uninstalling or clearing storage.
2. Open HydraMilk, choose local mode or sign in, and tap the **bell** at the top. You can also use **Family → Reminders**.
3. Turn on **Daily entry reminder** and allow notifications when Android asks. Tap its time to choose your own. The initial suggestion is 8:00 pm.
4. Optionally turn on **Monthly bill review**. This reminds you on the 1st to review last month's milk and water bills and record payments; the initial suggestion is 9:00 am. It appears regardless of balance.
5. Tap **Send a test notification** and check the notification tray. The test does not turn on recurring reminders.

Both reminders initially start OFF. Changes save automatically. Switch either off to cancel its schedule. These are per-phone settings, separate from the shared family ledger, and remain across app restarts/sign-out. Everyone who wants reminders must install this update and enable them on their own phone.

Tap a daily or test notification to open the current month register. Tap the monthly notification to open last month's Bills screen. If you are signed out, choose local mode or finish family sign-in first; the destination is retained until the ledger opens.

## Delivery and troubleshooting

The phone schedules notifications locally, so no internet, server subscription, Firebase account, or login is required for reminder delivery. Shared ledger operations still need internet. No family details, bill amounts, or invite codes are put in notifications.

Times use the phone's time zone, refreshed when HydraMilk opens/resumes. Reopen the app after travelling or changing the phone time zone. The schedule uses Android's inexact alarms to save battery and does not require exact-alarm access; delivery can be later than the selected time. The Android receivers restore saved schedules after reboot and app updates, subject to system restrictions.

If a reminder is missing:

- Open HydraMilk → bell → **Android notification settings**. Allow app notifications and the **Milk & water reminders** channel. Check Do Not Disturb and your phone's sound settings.
- Return to HydraMilk and tap **Retry** if shown. A saved reminder choice remains available after a permission is revoked; it is rescheduled when access is restored and the app resumes.
- Check your phone's battery/background-app restrictions. Force-stop blocks alarms until you open the app again. Some phone manufacturers restrict scheduled notifications more aggressively.
- Send a test notification. Test success confirms the request was handed to Android; the tray is the actual delivery check.

Notification scheduling, denied permissions, recurring IDs, cancellation, DST/calendar dates, persistence, and screen routing were checked automatically, including the real Dart plugin's platform-channel requests. Actual Android delivery, reboot recovery, and manufacturer battery behavior still need verification on a physical device. The first end-to-end check is the test button after installation.

These reminders cannot reach installations of the earlier APK. This release does not provide an administrator broadcast service or remote server-push campaigns.

## Developer notes

Versions are pinned in `pubspec.yaml` and `pubspec.lock`. The Android app enables core-library desugaring, requests `POST_NOTIFICATIONS` and `RECEIVE_BOOT_COMPLETED`, declares scheduled/boot receivers, and preserves the white droplet notification resource during release shrinking. Daily, monthly, and test IDs are distinct, so tests and rescheduling do not replace the other reminder. No database or authentication changes are needed.

References: [notification package setup](https://pub.dev/packages/flutter_local_notifications), [Android notification permission](https://developer.android.com/develop/ui/views/notifications/notification-permission), [Android alarms](https://developer.android.com/develop/background-work/services/alarms/schedule).
