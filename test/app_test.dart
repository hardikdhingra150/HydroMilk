import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:peach_ledger/main.dart';
import 'package:peach_ledger/store.dart';
import 'package:peach_ledger/models.dart';
import 'family_test.dart' show FamilyServer;

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  if (Platform.environment['HYDRAMILK_PREVIEWS'] != '1') return;
  ScaffoldMessenger.maybeOf(
    tester.element(find.byType(Scaffold).first),
  )?.removeCurrentSnackBar();
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('../$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void phone(WidgetTester tester, {double width = 390, double scale = 1}) {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<LedgerStore> localStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LedgerStore(await SharedPreferences.getInstance());
  await store.load();
  await store.chooseLocalMode();
  return store;
}

void main() {
  setUpAll(() async {
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
  for (final width in [320.0, 390.0, 1200.0]) {
    for (final scale in [1.0, 1.4]) {
      testWidgets(
        'Entries, bills, family and dated forms at $width / text $scale',
        (tester) async {
          phone(tester, width: width, scale: scale);
          final store = await localStore();
          await tester.pumpWidget(LedgerApp(store: store));
          await tester.pumpAndSettle();
          expect(find.text('HydraMilk'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('add-water')));
          await tester.pumpAndSettle();
          expect(find.text('Delivery date'), findsOneWidget);
          expect(find.textContaining(fullDate(DateTime.now())), findsWidgets);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Not received'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byKey(const ValueKey('save-entry')));
          await tester.tap(find.byKey(const ValueKey('save-entry')));
          await tester.pumpAndSettle();
          expect(store.entries.single.status, 'skipped');
          expect(store.entries.single.quantityMilli, greaterThan(0));
          expect(store.entries.single.amount, 0);
          for (final label in ['Bills', 'Family', 'Month']) {
            await tester.tap(find.text(label).last);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$label at $width / $scale',
            );
          }
        },
      );
    }
  }
  testWidgets(
    'Yesterday is saved, part/full payments change visible entry status and retain payment dates',
    (tester) async {
      phone(tester);
      final store = await localStore();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LedgerApp(store: store),
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, key, 'HydraMilk-empty');
      await tester.tap(find.byKey(const ValueKey('add-milk')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yesterday'));
      await tester.pumpAndSettle();
      final yesterday = DateUtils.dateOnly(
        DateTime.now(),
      ).subtract(const Duration(days: 1));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantity (L)'),
        '1.5',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Price per litre (INR)'),
        '60',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-entry')));
      await tester.pumpAndSettle();
      await capture(tester, key, 'HydraMilk-date-entry');
      await tester.tap(find.byKey(const ValueKey('save-entry')));
      await tester.pumpAndSettle();
      expect(store.entries.single.date, dayKey(yesterday));
      expect(store.entries.single.amount, 9000);
      await tester.tap(find.text('Entry list'));
      await tester.pumpAndSettle();
      expect(find.text('Unpaid'), findsWidgets);
      await tester.tap(find.text('Bills').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('pay-milk')));
      await tester.tap(find.byKey(const ValueKey('pay-milk')));
      await tester.pumpAndSettle();
      expect(find.text('Payment date'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount paid (INR)'),
        '30',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-payment')));
      await tester.tap(find.byKey(const ValueKey('save-payment')));
      await tester.pumpAndSettle();
      expect(store.payments.single.date, dayKey(DateTime.now()));
      expect(store.paidForEntry(store.entries.single), 3000);
      expect(find.text('Part paid'), findsOneWidget);
      await tester.tap(find.text('Month').last);
      await tester.pumpAndSettle();
      expect(find.text('Part paid'), findsOneWidget);
      await tester.tap(find.text('Bills').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pay-milk')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Amount paid (INR)'),
            )
            .controller!
            .text,
        '60.00',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-payment')));
      await tester.tap(find.byKey(const ValueKey('save-payment')));
      await tester.pumpAndSettle();
      expect(store.paidForEntry(store.entries.single), 9000);
      expect(find.text('Paid'), findsWidgets);
      await capture(tester, key, 'HydraMilk-paid-bills');
      await tester.tap(find.text('Month').last);
      await tester.pumpAndSettle();
      expect(find.text('Paid'), findsWidgets);
      await capture(tester, key, 'HydraMilk-paid-entries');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'A real price is required, quantity presets calculate correctly, full date can be typed',
    (tester) async {
      phone(tester);
      final store = await localStore();
      await tester.pumpWidget(LedgerApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-water')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('Delivery date')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Switch to input'));
      await tester.pumpAndSettle();
      final dateField = find.byType(TextField).last;
      // HydraMilk uses an explicit day/month/year date format.
      await tester.enterText(dateField, '29/02/2024');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('29 Feb 2024'), findsOneWidget);
      await tester.tap(find.text('2 cans'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('save-entry')));
      await tester.tap(find.byKey(const ValueKey('save-entry')));
      await tester.pumpAndSettle();
      expect(store.entries, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Price per can (INR)'),
        '35',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-entry')));
      await tester.tap(find.byKey(const ValueKey('save-entry')));
      await tester.pumpAndSettle();
      expect(store.entries.single.date, '2024-02-29');
      expect(store.entries.single.amount, 7000);
      expect(find.text('February 2024'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Create and join forms work, invalid codes show an inline error, family code stays accessible',
    (tester) async {
      phone(tester);
      SharedPreferences.setMockInitialValues({});
      final server = FamilyServer();
      final owner = (await tester.runAsync(
        () => server.open('owner@example.com', registerDispose: false),
      ))!;
      addTearDown(() => tester.runAsync(owner.client!.dispose));
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LedgerApp(key: const ValueKey('owner-app'), store: owner),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a family'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('member-name')),
        'Parent',
      );
      await tester.enterText(
        find.byKey(const ValueKey('family-name-code')),
        'Our home',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-family')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('save-family')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(owner.cloud, true);
      expect(find.text(owner.inviteCode!), findsOneWidget);
      expect(find.text('Copy code'), findsOneWidget);
      await capture(tester, key, 'HydraMilk-family');
      final member = (await tester.runAsync(
        () => server.open('member@example.com', registerDispose: false),
      ))!;
      addTearDown(() => tester.runAsync(member.client!.dispose));
      await tester.pumpWidget(
        LedgerApp(key: const ValueKey('member-app'), store: member),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join a family'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('member-name')),
        'Child',
      );
      await tester.enterText(
        find.byKey(const ValueKey('family-name-code')),
        'WRONG',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-family')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('save-family')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(
            'Invite code not found. Check it with your family.',
          ),
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('family-name-code')),
        owner.inviteCode!,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-family')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('save-family')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(member.familyId, owner.familyId);
      expect(find.text('Family connected'), findsOneWidget);
      expect(find.text('Parent'), findsOneWidget);
      expect(find.text('Child'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Whole month shows unrecorded dates, multiple deliveries, paid status and editing by date',
    (tester) async {
      phone(tester, width: 320, scale: 1.4);
      final store = await localStore();
      final now = DateTime.now();
      final first = DateTime(now.year, now.month, 1);
      for (final entry in [
        Delivery(
          id: 'm1',
          service: 'milk',
          date: dayKey(first),
          quantityMilli: 1000,
          ratePaise: 6000,
        ),
        Delivery(
          id: 'm2',
          service: 'milk',
          date: dayKey(first),
          quantityMilli: 500,
          ratePaise: 6000,
        ),
        Delivery(
          id: 's',
          service: 'milk',
          date: dayKey(first),
          quantityMilli: 1000,
          ratePaise: 6000,
          status: 'skipped',
        ),
        Delivery(
          id: 'w',
          service: 'water',
          date: dayKey(first),
          quantityMilli: 2000,
          ratePaise: 3500,
        ),
      ]) {
        await store.saveDelivery(entry);
      }
      await store.savePayment(
        Payment(
          id: 'p',
          service: 'milk',
          month: dayKey(first),
          date: dayKey(first),
          amount: 3000,
        ),
      );
      await tester.pumpWidget(LedgerApp(store: store));
      await tester.pumpAndSettle();
      final scroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('cell-milk-${dayKey(first)}')),
        200,
        scrollable: scroll,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Part paid'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('cell-milk-${dayKey(first)}')));
      await tester.pumpAndSettle();
      expect(find.text(fullDate(first)), findsOneWidget);
      await tester.ensureVisible(find.text('0.5 L'));
      await tester.tap(find.text('0.5 L'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantity (L)'),
        '2',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-entry')));
      await tester.tap(find.byKey(const ValueKey('save-entry')));
      await tester.pumpAndSettle();
      expect(store.daysForMonth(first).first.milk.quantityMilli, 3000);
      expect(store.daysForMonth(first).first.milk.amount, 18000);
      final last = DateTime(now.year, now.month + 1, 0);
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('month-day-${dayKey(last)}')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('cell-water-${dayKey(last)}')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ValueKey('cell-water-${dayKey(last)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-day-water')));
      await tester.pumpAndSettle();
      expect(find.textContaining(fullDate(last)), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Price per can (INR)'),
        '35',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-entry')));
      await tester.tap(find.byKey(const ValueKey('save-entry')));
      await tester.pumpAndSettle();
      expect(
        store.entries.any(
          (e) => e.date == dayKey(last) && e.service == 'water',
        ),
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Month dashboard has both service totals and a complete day register',
    (tester) async {
      phone(tester);
      final store = await localStore();
      final today = DateTime.now();
      final first = DateTime(today.year, today.month, 1);
      for (int day = 1; day <= 4; day++) {
        await store.saveDelivery(
          Delivery(
            id: 'milk-$day',
            service: 'milk',
            date: dayKey(DateTime(today.year, today.month, day)),
            quantityMilli: 1000,
            ratePaise: 6000,
            status: day == 3 ? 'skipped' : 'delivered',
          ),
        );
        if (day == 1 || day == 4) {
          await store.saveDelivery(
            Delivery(
              id: 'water-$day',
              service: 'water',
              date: dayKey(DateTime(today.year, today.month, day)),
              quantityMilli: 1000,
              ratePaise: 3500,
            ),
          );
        }
      }
      await store.savePayment(
        Payment(
          id: 'paid-milk',
          service: 'milk',
          month: dayKey(first),
          date: dayKey(first),
          amount: 9000,
        ),
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LedgerApp(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('month-day-count')), findsOneWidget);
      await capture(tester, key, 'HydraMilk-month-overview');
      await tester.scrollUntilVisible(
        find.byKey(
          ValueKey('month-day-${dayKey(DateTime(today.year, today.month, 4))}'),
        ),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await capture(tester, key, 'HydraMilk-month-register');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Google is on first launch, uses external PKCE and can be cancelled; email signup is visible',
    (tester) async {
      phone(tester);
      SharedPreferences.setMockInitialValues({});
      final launcher = RecordingLauncher();
      final old = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = old);
      final client = (await tester.runAsync(() async {
        final client = SupabaseClient(
          'https://example.supabase.co',
          'sb_publishable_test',
          authOptions: AuthClientOptions(
            autoRefreshToken: false,
            authFlowType: AuthFlowType.pkce,
            pkceAsyncStorage: MemoryAuthStorage(),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return client;
      }))!;
      addTearDown(() => tester.runAsync(client.dispose));
      final store = LedgerStore(
        await SharedPreferences.getInstance(),
        client: client,
      );
      await store.load();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LedgerApp(store: store),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/peach_pup.png'),
          key.currentContext!,
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, key, 'HydraMilk-welcome');
      await tester.tap(find.byKey(const ValueKey('welcome-google')));
      await tester.pumpAndSettle();
      final url = Uri.parse(launcher.url!);
      expect(url.queryParameters['provider'], 'google');
      expect(url.queryParameters['redirect_to'], authCallback);
      expect(url.queryParameters['code_challenge'], isNotEmpty);
      expect(launcher.options!.mode, PreferredLaunchMode.externalApplication);
      await tester.ensureVisible(find.text('Cancel sign-in'));
      await tester.tap(find.text('Cancel sign-in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('welcome-email')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
      await tester.ensureVisible(find.text('New here? Create an account'));
      await tester.tap(find.text('New here? Create an account'));
      await tester.pumpAndSettle();
      expect(find.text('Create account'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class RecordingLauncher extends UrlLauncherPlatform {
  String? url;
  LaunchOptions? options;
  @override
  Null get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    this.url = url;
    this.options = options;
    return true;
  }
}

class MemoryAuthStorage extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    values.remove(key);
  }
}
