import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models.dart';
import 'store.dart';

const peach = Color(0xFFF7B9A0);
const paper = Color(0xFFF6F7F2);
const ink = Color(0xFF173F3B);
const muted = Color(0xFF566965);
const orange = Color(0xFFAF4E2E);
const teal = Color(0xFF1C6961);
const line = Color(0xFFDDE5DF);
const sage = Color(0xFF356946);
const blue = Color(0xFF356C83);
const cloudUrl = String.fromEnvironment('SUPABASE_URL');
const cloudKey = String.fromEnvironment('SUPABASE_ANON_KEY');
// Keep the installed package and approved callback stable across the rename.
const authCallback = 'com.familyledger.peachledger://login-callback';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SupabaseClient? client;
  String? error;
  try {
    if (cloudUrl.isNotEmpty && cloudKey.isNotEmpty) {
      await Supabase.initialize(
        url: cloudUrl,
        publishableKey: cloudKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
      );
      client = Supabase.instance.client;
    }
  } catch (_) {
    error = 'Sign-in could not start. Close and reopen HydraMilk to try again.';
  }
  final store = LedgerStore(
    await SharedPreferences.getInstance(),
    client: client,
  );
  try {
    await store.load();
  } catch (_) {
    error = 'Could not load your family. Check your connection and tap Retry.';
  }
  runApp(LedgerApp(store: store, startupError: error));
}

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key, required this.store, this.startupError});
  final LedgerStore store;
  final String? startupError;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HydraMilk',
    locale: const Locale('en', 'GB'),
    supportedLocales: const [Locale('en', 'GB')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: teal,
        primary: teal,
        surface: paper,
        onSurface: ink,
      ),
      fontFamily: 'DMSans',
      textTheme: ThemeData.light().textTheme.apply(
        fontFamily: 'DMSans',
        bodyColor: ink,
        displayColor: ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        contentPadding: const EdgeInsets.all(16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 54),
          textStyle: const TextStyle(
            fontFamily: 'DMSans',
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(48, 52),
          side: const BorderSide(color: line),
          textStyle: const TextStyle(fontFamily: 'DMSans', fontSize: 16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ink,
        behavior: SnackBarBehavior.floating,
      ),
      dividerColor: line,
    ),
    home: LedgerHome(store: store, startupError: startupError),
  );
}

String serviceName(String s) => s == 'milk' ? 'Milk' : 'Water';
String unit(String s) => s == 'milk' ? 'L' : 'cans';
String fullDate(DateTime d) => DateFormat('d MMM yyyy').format(d);
IconData serviceIcon(String s) =>
    s == 'milk' ? Icons.local_drink_outlined : Icons.water_drop_outlined;

class LedgerHome extends StatefulWidget {
  const LedgerHome({super.key, required this.store, this.startupError});
  final LedgerStore store;
  final String? startupError;
  @override
  State<LedgerHome> createState() => _LedgerHomeState();
}

class _LedgerHomeState extends State<LedgerHome> with WidgetsBindingObserver {
  LedgerStore get store => widget.store;
  int tab = 0;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  String statusFilter = 'All';
  String monthView = 'Month view';
  bool busy = false, googlePending = false;
  bool foreground = true;
  String? lastActionError;
  StreamSubscription<AuthState>? authSubscription;
  Timer? syncTimer;
  @override
  void initState() {
    super.initState();
    store.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    authSubscription = store.client?.auth.onAuthStateChange.listen(
      (event) {
        if (event.event == AuthChangeEvent.signedIn) {
          // Leave the auth callback before making further Supabase requests.
          unawaited(
            Future<void>(() async {
              if (!mounted) return;
              setState(() {
                googlePending = false;
                tab = 0;
              });
              await refreshFamily();
            }),
          );
        } else if (event.event == AuthChangeEvent.signedOut) {
          unawaited(store.resetAfterSignOut());
        }
      },
      onError: (Object _) {
        if (mounted) {
          setState(() => googlePending = false);
          message('Sign-in did not finish. Please try again.');
        }
      },
    );
    syncTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (foreground && store.cloud && !busy && !store.refreshing) {
        unawaited(refreshFamily(quiet: true));
      }
    });
    if (widget.startupError != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => message(widget.startupError!),
      );
    }
  }

  @override
  void dispose() {
    syncTimer?.cancel();
    authSubscription?.cancel();
    store.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && store.connected && !busy) {
      unawaited(refreshFamily(quiet: true));
    }
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  String money(int value) => NumberFormat.currency(
    symbol:
        {
          'INR': '₹',
          'USD': '\$',
          'EUR': '€',
          'GBP': '£',
        }[store.settings.currency] ??
        store.settings.currency,
    decimalDigits: value % 100 == 0 ? 0 : 2,
  ).format(value / 100);
  Future<bool> action(Future<void> Function() work, [String? success]) async {
    if (busy) return false;
    setState(() {
      busy = true;
      lastActionError = null;
    });
    try {
      await work();
      if (success != null) message(success);
      return true;
    } catch (e) {
      lastActionError = (e is AuthException
          ? e.message
          : e is PostgrestException
          ? e.message
          : e is StateError
          ? e.message
          : 'Could not complete this. Check your connection and try again.');
      message(lastActionError!);
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refreshFamily({bool quiet = false}) async {
    if (!store.connected) return;
    try {
      await store.refresh();
    } catch (_) {
      if (!quiet) {
        message(
          'Could not load your family. Check your connection and tap Retry.',
        );
      }
    }
  }

  Future<void> googleSignIn() async {
    if (store.client == null || busy || googlePending) return;
    setState(() => googlePending = true);
    try {
      final launched = await store.client!.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kIsWeb
            ? Uri.base.replace(query: '', fragment: '').toString()
            : authCallback,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!launched) throw StateError('Browser unavailable');
    } catch (_) {
      if (mounted) setState(() => googlePending = false);
      message('Google sign-in did not open. Try again, or sign in with email.');
    }
  }

  Widget brand() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: ink,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.water_drop_rounded, color: peach, size: 23),
      ),
      const SizedBox(width: 10),
      const Text(
        'HydraMilk',
        style: TextStyle(
          fontSize: 25,
          fontWeight: FontWeight.w800,
          letterSpacing: -1,
        ),
      ),
    ],
  );
  Widget card(Widget child, {Color color = Colors.white}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: line),
    ),
    child: child,
  );
  Widget title(String text) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 14),
    child: Text(
      text,
      style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
    ),
  );
  Widget formError() => lastActionError == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            lastActionError!,
            style: const TextStyle(
              color: Color(0xFFB3261E),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
  Widget note(String text) => Text(
    text,
    style: const TextStyle(fontSize: 15, color: muted, height: 1.5),
  );
  Widget badge(String text, {Color color = orange}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 14, color: color, fontWeight: FontWeight.w700),
    ),
  );
  Widget amountRow(String text, int amount, {bool strong = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 16,
              color: strong ? ink : muted,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            money(amount),
            style: TextStyle(
              fontSize: strong ? 22 : 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
  Widget scrollPage(List<Widget> children) => RefreshIndicator(
    onRefresh: () => refreshFamily(),
    child: SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ),
  );
  Widget waitingGoogle() => card(
    Column(
      children: [
        const Text(
          'Finish Google sign-in in your browser.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        TextButton(
          onPressed: () => setState(() => googlePending = false),
          child: const Text('Cancel sign-in'),
        ),
      ],
    ),
    color: const Color(0xFFFFEADC),
  );

  @override
  Widget build(BuildContext context) {
    if (!store.connected && !store.localModeChosen) return welcome();
    if (store.connected && !store.familyLoaded) return loadFamilyPage();
    if (store.connected && !store.cloud) return familySetupPage();
    return Scaffold(
      appBar: AppBar(
        title: brand(),
        actions: [
          if (store.cloud)
            IconButton(
              tooltip: 'Refresh family',
              onPressed: busy || store.refreshing
                  ? null
                  : () => refreshFamily(),
              icon: const Icon(Icons.sync_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (busy || store.refreshing)
              const LinearProgressIndicator(minHeight: 2),
            if (store.syncPending)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: TextButton.icon(
                  onPressed: busy ? null : () => refreshFamily(),
                  icon: const Icon(Icons.sync_problem_outlined),
                  label: const Text(
                    'Connection interrupted. Tap to reload family.',
                  ),
                ),
              ),
            if (googlePending)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: waitingGoogle(),
              ),
            if (tab != 2)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
                child: monthPicker(),
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: KeyedSubtree(
                  key: ValueKey(tab),
                  child: [entriesPage, billsPage, familyPage][tab](),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tab == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('add-milk'),
                        onPressed: busy ? null : () => entryForm('milk'),
                        icon: const Icon(Icons.add),
                        label: const Text('Milk'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('add-water'),
                        onPressed: busy ? null : () => entryForm('water'),
                        icon: const Icon(Icons.add),
                        label: const Text('Water'),
                        style: FilledButton.styleFrom(backgroundColor: blue),
                      ),
                    ),
                  ],
                ),
              ),
            NavigationBar(
              height: 70,
              selectedIndex: tab,
              backgroundColor: paper,
              indicatorColor: peach.withValues(alpha: .6),
              labelTextStyle: WidgetStateProperty.all(
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              onDestinationSelected: (value) => setState(() => tab = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.calendar_month_rounded),
                  label: 'Month',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  label: 'Bills',
                ),
                NavigationDestination(
                  icon: Icon(Icons.people_outline),
                  label: 'Family',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget welcome() => Scaffold(
    body: SafeArea(
      child: scrollPage([
        const SizedBox(height: 18),
        brand(),
        const SizedBox(height: 20),
        ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Image.asset(
            'assets/peach_pup.png',
            height: 120,
            fit: BoxFit.cover,
            alignment: const Alignment(0, .25),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Milk. Water. Sorted.',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        note(
          'Add deliveries, check what you owe, and share one ledger with your family.',
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const ValueKey('welcome-google'),
          onPressed: store.client == null || googlePending || busy
              ? null
              : googleSignIn,
          icon: const Icon(Icons.account_circle_outlined),
          label: const Text('Continue with Google'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('welcome-email'),
          onPressed: store.client == null || googlePending || busy
              ? null
              : emailForm,
          icon: const Icon(Icons.email_outlined),
          label: const Text('Sign in with email'),
        ),
        const SizedBox(height: 16),
        if (googlePending) waitingGoogle(),
        if (store.client == null)
          note(
            'Family sign-in is unavailable in this build. You can use this phone’s ledger.',
          ),
        TextButton(
          onPressed: googlePending || busy
              ? null
              : () => action(store.chooseLocalMode),
          child: const Text(
            'Use without an account',
            style: TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(height: 10),
        note('Starts empty. Only the entries you add count towards your bill.'),
      ]),
    ),
  );
  Widget loadFamilyPage() => Scaffold(
    appBar: AppBar(title: brand()),
    body: SafeArea(
      child: scrollPage([
        const SizedBox(height: 40),
        const Icon(Icons.cloud_sync_outlined, size: 56, color: orange),
        title('Load your family'),
        note(
          'You’re signed in. We need a connection to load your family before you can add records.',
        ),
        const SizedBox(height: 22),
        if (store.refreshing || busy)
          const Center(child: CircularProgressIndicator())
        else
          FilledButton(
            onPressed: () => refreshFamily(),
            child: const Text('Retry'),
          ),
        TextButton(
          onPressed: busy ? null : () => action(store.signOut),
          child: const Text('Sign out'),
        ),
      ]),
    ),
  );
  Widget familySetupPage() => Scaffold(
    appBar: AppBar(title: brand()),
    body: SafeArea(
      child: scrollPage([
        title('One family. One shared bill.'),
        note(
          'You’re signed in as ${store.client?.auth.currentUser?.email ?? 'a family member'}. Choose one option to continue.',
        ),
        const SizedBox(height: 22),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'First person in your family?',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              note(
                'Create an empty ledger, then give the family code to everyone else.',
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: busy ? null : () => familyForm(),
                child: const Text('Create a family'),
              ),
            ],
          ),
          color: const Color(0xFFFFEADC),
        ),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Already have a family code?',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              note(
                'Ask the person who created your family for their invite code.',
              ),
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: busy ? null : () => familyForm(join: true),
                child: const Text('Join a family'),
              ),
            ],
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        TextButton(
          onPressed: busy ? null : () => refreshFamily(),
          child: const Text('Already joined? Reload family'),
        ),
        TextButton(
          onPressed: busy ? null : () => action(store.signOut),
          child: const Text('Sign out'),
        ),
      ]),
    ),
  );

  Widget monthPicker() => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: line),
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Previous month',
          onPressed: () =>
              setState(() => month = DateTime(month.year, month.month - 1)),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: TextButton(
            onPressed: chooseMonth,
            child: Text(
              DateFormat('MMMM yyyy').format(month),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Next month',
          onPressed: () =>
              setState(() => month = DateTime(month.year, month.month + 1)),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
  Future<void> chooseMonth() async {
    int year = month.year, selectedMonth = month.month;
    final result = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Choose month & year'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  key: const ValueKey('year-choice'),
                  initialValue: year,
                  decoration: const InputDecoration(labelText: 'Year'),
                  items: [
                    for (
                      int i = math.min(2000, month.year);
                      i <= math.max(DateTime.now().year + 10, month.year);
                      i++
                    )
                      DropdownMenuItem(value: i, child: Text('$i')),
                  ],
                  onChanged: (value) => update(() => year = value!),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  key: const ValueKey('month-choice'),
                  initialValue: selectedMonth,
                  decoration: const InputDecoration(labelText: 'Month'),
                  items: [
                    for (int i = 1; i <= 12; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          DateFormat('MMMM').format(DateTime(2000, i)),
                        ),
                      ),
                  ],
                  onChanged: (value) => update(() => selectedMonth = value!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, DateTime(year, selectedMonth)),
              child: const Text('Show month'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) setState(() => month = result);
  }

  String billStatus(String service) {
    final total = store.total(month, service),
        paid = store.paid(month, service);
    return total == 0
        ? (paid > 0 ? 'Credit' : 'No bill yet')
        : paid >= total
        ? 'Paid'
        : paid > 0
        ? 'Part paid'
        : 'Unpaid';
  }

  Widget entriesPage() {
    final days = store.daysForMonth(month);
    final rows = store.forMonth(month).where((entry) {
      final applied = store.paidForEntry(entry);
      return statusFilter == 'All' ||
          (entry.amount > 0 &&
              (statusFilter == 'Paid'
                  ? applied >= entry.amount
                  : applied < entry.amount));
    }).toList();
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final rowHeight = math.max(90.0, 90 * scale);
    final recorded = days.where((day) => day.hasEntries).length;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: RefreshIndicator(
          onRefresh: () => refreshFamily(),
          child: CustomScrollView(
            key: PageStorageKey('month-${dayKey(month)}-$monthView'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Your month, together',
                              style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.5,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Export this month',
                            onPressed: exportCsv,
                            icon: const Icon(
                              Icons.ios_share_outlined,
                              size: 21,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${days.length} days · $recorded recorded',
                        key: const ValueKey('month-day-count'),
                        style: const TextStyle(fontSize: 14, color: muted),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: monthServiceTotal('milk', days)),
                          const SizedBox(width: 12),
                          Expanded(child: monthServiceTotal('water', days)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      monthBalance(),
                      const SizedBox(height: 18),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'Month view',
                            icon: Icon(Icons.view_week_outlined, size: 18),
                            label: Text('Month view'),
                          ),
                          ButtonSegment(
                            value: 'Entry list',
                            icon: Icon(Icons.format_list_bulleted, size: 18),
                            label: Text('Entry list'),
                          ),
                        ],
                        selected: {monthView},
                        showSelectedIcon: false,
                        onSelectionChanged: (value) =>
                            setState(() => monthView = value.first),
                        style: ButtonStyle(
                          visualDensity: VisualDensity.standard,
                          textStyle: WidgetStateProperty.all(
                            const TextStyle(
                              fontFamily: 'DMSans',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (monthView == 'Month view')
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Tap a day to add or review. No entry means nothing has been recorded.',
                            style: TextStyle(
                              fontSize: 13,
                              color: muted,
                              height: 1.4,
                            ),
                          ),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: ['All', 'Unpaid', 'Paid']
                              .map(
                                (status) => ChoiceChip(
                                  label: Text(status),
                                  selected: statusFilter == status,
                                  onSelected: (_) =>
                                      setState(() => statusFilter = status),
                                ),
                              )
                              .toList(),
                        ),
                    ],
                  ),
                ),
              ),
              if (monthView == 'Month view') ...[
                SliverPersistentHeader(
                  pinned: true,
                  delegate: MonthTableHeader(
                    height: math.max(
                      52,
                      MediaQuery.textScalerOf(context).scale(16) + 28,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: const BoxDecoration(
                        color: paper,
                        border: Border(bottom: BorderSide(color: line)),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 48,
                            child: Text(
                              'DATE',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: muted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Row(
                              children: [
                                Icon(
                                  serviceIcon('milk'),
                                  size: 18,
                                  color: orange,
                                ),
                                const SizedBox(width: 6),
                                const Flexible(
                                  child: Text(
                                    'Milk',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Row(
                              children: [
                                Icon(
                                  serviceIcon('water'),
                                  size: 18,
                                  color: blue,
                                ),
                                const SizedBox(width: 6),
                                const Flexible(
                                  child: Text(
                                    'Water',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverFixedExtentList(
                    itemExtent: rowHeight,
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => monthDayRow(days[index]),
                      childCount: days.length,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
                    child: Column(
                      children: [
                        Text(
                          'End of ${DateFormat('MMMM yyyy').format(month)}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'No entry · Not received · Paid / Unpaid',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                if (rows.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: card(
                        note(
                          statusFilter == 'All'
                              ? 'No entries for this month. Use + Milk or + Water to start.'
                              : 'No ${statusFilter.toLowerCase()} entries for this month.',
                        ),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => entryCard(rows[index]),
                      childCount: rows.length,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String quantityLabel(int quantity, String service) =>
      '${quantityText(quantity)} ${service == 'milk'
          ? 'L'
          : quantity == 1000
          ? 'can'
          : 'cans'}';
  Widget monthServiceTotal(String service, List<LedgerDay> days) {
    final quantity = days.fold(
      0,
      (sum, day) => sum + day.forService(service).quantityMilli,
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: service == 'milk'
            ? const Color(0xFFFFEBDD)
            : const Color(0xFFE2EFEC),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                serviceIcon(service),
                color: service == 'milk' ? orange : teal,
                size: 20,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  serviceName(service),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            quantityLabel(quantity, service),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            money(store.total(month, service)),
            style: const TextStyle(
              fontSize: 16,
              color: muted,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget monthBalance() {
    final total = store.total(month),
        paid = store.paid(month, 'milk') + store.paid(month, 'water');
    return Semantics(
      button: true,
      label: 'Open bills and payments',
      child: InkWell(
        onTap: () => setState(() => tab = 1),
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: ink,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      paid > total ? 'Credit this month' : 'Left to pay',
                      style: const TextStyle(
                        color: Color(0xFFD3E5DF),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      money((total - paid).abs()),
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Paid ${money(paid)}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_rounded, color: peach, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget monthDayRow(LedgerDay day) {
    final isToday = dayKey(day.date) == dayKey(DateTime.now());
    return Container(
      key: ValueKey('month-day-${dayKey(day.date)}'),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: InkWell(
              key: ValueKey('date-${dayKey(day.date)}'),
              onTap: busy ? null : () => dayDetails(day),
              borderRadius: BorderRadius.circular(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: isToday ? teal : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      DateFormat('dd').format(day.date),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: isToday ? Colors.white : ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    DateFormat('EEE').format(day.date),
                    style: const TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: monthCell(day, 'milk')),
          const SizedBox(width: 10),
          Expanded(child: monthCell(day, 'water')),
        ],
      ),
    );
  }

  Widget monthCell(LedgerDay day, String service) {
    final group = day.forService(service),
        serviceColor = service == 'milk' ? orange : teal;
    final color = group.paymentStatus == 'Paid'
        ? sage
        : group.paymentStatus == 'No entry' ||
              group.paymentStatus == 'Not received' ||
              group.paymentStatus == 'No charge'
        ? muted
        : orange;
    final status = group.paymentStatus;
    return Semantics(
      button: true,
      label:
          '${serviceName(service)}, ${fullDate(day.date)}, ${group.paymentStatus}, ${quantityLabel(group.quantityMilli, service)}, ${money(group.amount)}',
      child: InkWell(
        key: ValueKey('cell-$service-${dayKey(day.date)}'),
        onTap: busy ? null : () => dayDetails(day, service: service),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: group.hasEntries ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: group.hasEntries ? line : line.withValues(alpha: .55),
            ),
          ),
          child: group.hasEntries
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (group.receivedCount > 0)
                      Text(
                        quantityLabel(group.quantityMilli, service),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: serviceColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    if (group.receivedCount > 0)
                      Text(
                        money(group.amount),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(
                      status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 18,
                      color: muted,
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'No entry',
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> dayDetails(LedgerDay day, {String? service}) async {
    Delivery? edit;
    String? addService;
    await sheet(
      Builder(
        builder: (ctx) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              fullDate(day.date),
              style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            note(DateFormat('EEEE').format(day.date)),
            const SizedBox(height: 20),
            ...[
              if (service == null || service == 'milk') 'milk',
              if (service == null || service == 'water') 'water',
            ].map((selected) {
              final group = day.forService(selected);
              return card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          serviceIcon(selected),
                          color: selected == 'milk' ? orange : teal,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            serviceName(selected),
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!group.hasEntries)
                      note('Nothing recorded for this date.'),
                    ...group.entries.map(
                      (entry) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          entry.status == 'skipped'
                              ? 'Not received'
                              : quantityLabel(entry.quantityMilli, selected),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          entry.note.isEmpty
                              ? (entry.status == 'skipped'
                                    ? 'No charge'
                                    : '${money(entry.ratePaise)} per ${selected == 'milk' ? 'litre' : 'can'}')
                              : entry.note,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              money(entry.amount),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.edit_outlined, size: 18),
                          ],
                        ),
                        onTap: () {
                          edit = entry;
                          Navigator.pop(ctx);
                        },
                      ),
                    ),
                    if (group.hasEntries)
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            badge(
                              group.paymentStatus,
                              color: group.paymentStatus == 'Paid'
                                  ? sage
                                  : muted,
                            ),
                            if (group.receivedCount > 0)
                              badge('${money(group.paid)} paid', color: teal),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: ValueKey('add-day-$selected'),
                      onPressed: () {
                        addService = selected;
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.add_rounded),
                      label: Text('Add ${serviceName(selected).toLowerCase()}'),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (edit != null) {
      await entryForm(edit!.service, existing: edit);
    } else if (addService != null) {
      await entryForm(addService!, initialDate: day.date);
    }
  }

  Widget entryCard(Delivery entry) {
    final applied = store.paidForEntry(entry);
    final status = entry.status == 'skipped'
        ? 'Not received'
        : entry.amount == 0
        ? 'No charge'
        : applied >= entry.amount
        ? 'Paid'
        : applied > 0
        ? 'Part paid'
        : 'Unpaid';
    return Semantics(
      button: true,
      label:
          'Edit ${serviceName(entry.service)} on ${fullDate(DateTime.parse(entry.date))}',
      child: InkWell(
        onTap: busy ? null : () => entryForm(entry.service, existing: entry),
        borderRadius: BorderRadius.circular(20),
        child: card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${fullDate(DateTime.parse(entry.date))} · ${DateFormat('EEEE').format(DateTime.parse(entry.date))}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    serviceIcon(entry.service),
                    color: entry.service == 'milk' ? orange : blue,
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${serviceName(entry.service)} · ${quantityText(entry.quantityMilli)} ${unit(entry.service)}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      money(entry.amount),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  badge(
                    status,
                    color: status == 'Paid'
                        ? sage
                        : status == 'Not received' || status == 'No charge'
                        ? muted
                        : orange,
                  ),
                  if (applied > 0 && applied < entry.amount)
                    Text(
                      '${money(applied)} paid',
                      style: const TextStyle(fontSize: 14, color: muted),
                    ),
                  const Text(
                    'Tap to edit',
                    style: TextStyle(fontSize: 14, color: muted),
                  ),
                ],
              ),
              if (entry.note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: note(entry.note),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget billsPage() {
    final payments =
        store.payments.where((p) => p.month == dayKey(month)).toList()
          ..sort((a, b) => b.date.compareTo(a.date));
    return scrollPage([
      title('Monthly bills'),
      ...['milk', 'water'].map((service) {
        final total = store.total(month, service),
            paid = store.paid(month, service),
            balance = total - paid;
        return card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 10,
                runSpacing: 8,
                children: [
                  Text(
                    serviceName(service),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  badge(
                    billStatus(service),
                    color: total > 0 && paid >= total
                        ? sage
                        : total == 0
                        ? muted
                        : orange,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (total == 0 && paid == 0)
                note(
                  'Add a ${serviceName(service).toLowerCase()} entry to start.',
                )
              else ...[
                amountRow('Total bill', total),
                amountRow('Already paid', paid),
                const Divider(height: 24),
                amountRow(
                  balance < 0 ? 'Credit' : 'Left to pay',
                  balance.abs(),
                  strong: true,
                ),
                if (balance > 0) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    key: ValueKey('pay-$service'),
                    onPressed: busy ? null : () => paymentForm(service),
                    child: Text('Mark paid · ${money(balance)}'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => paymentForm(service),
                    child: const Text('Record a part payment'),
                  ),
                ],
              ],
            ],
          ),
        );
      }),
      note(
        'Recording a payment updates these badges and your entries. Payments cover the oldest deliveries first, within the same month and supplier.',
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Record another payment or advance'),
        children: [
          Wrap(
            spacing: 10,
            children: ['milk', 'water']
                .map(
                  (service) => OutlinedButton(
                    onPressed: busy ? null : () => paymentForm(service),
                    child: Text(serviceName(service)),
                  ),
                )
                .toList(),
          ),
        ],
      ),
      title('Payment history'),
      if (payments.isEmpty)
        card(
          note(
            'No payments recorded for ${DateFormat('MMMM yyyy').format(month)}.',
          ),
        ),
      ...payments.map(
        (p) => card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paid ${money(p.amount)} · ${serviceName(p.service)}',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Paid on ${fullDate(DateTime.parse(p.date))}',
                style: const TextStyle(fontSize: 16),
              ),
              Text(
                'Bill for ${DateFormat('MMMM yyyy').format(DateTime.parse(p.month))}',
                style: const TextStyle(fontSize: 14, color: muted),
              ),
              if (p.note.isNotEmpty) note(p.note),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        if (await confirm(
                          'Remove this payment?',
                          'Only the payment record is removed. The unpaid amount will be recalculated.',
                        )) {
                          await action(
                            () => store.deletePayment(p.id),
                            'Payment removed',
                          );
                        }
                      },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove incorrect payment'),
              ),
            ],
          ),
        ),
      ),
    ]);
  }

  Widget familyPage() => scrollPage([
    title(store.cloud ? store.settings.name : 'Family sharing'),
    if (store.cloud) ...[
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            badge(
              store.syncPending ? 'Needs a refresh' : 'Family connected',
              color: store.syncPending ? orange : sage,
            ),
            const SizedBox(height: 12),
            note(store.client?.auth.currentUser?.email ?? 'Signed in'),
            if (store.lastSyncedAt != null)
              note(
                'Last updated ${DateFormat('h:mm a').format(store.lastSyncedAt!)} · refreshes automatically',
              ),
            const SizedBox(height: 16),
            const Text(
              'Invite your family',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            note(
              'Ask each person to sign in, choose Join a family, and enter this code.',
            ),
            const SizedBox(height: 14),
            SelectableText(
              store.inviteCode ?? 'Tap refresh to load code',
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: store.inviteCode == null
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: store.inviteCode!),
                          );
                          message('Family code copied');
                        },
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy code'),
                ),
                OutlinedButton.icon(
                  onPressed: store.inviteCode == null ? null : shareInvite,
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Share code'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            note(
              'Keep this code private. Family members can add and edit shared records.',
            ),
          ],
        ),
        color: const Color(0xFFFFEADC),
      ),
      title('Family members'),
      card(
        Column(
          children: store.members
              .map(
                (m) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: paper,
                    child: Icon(Icons.person_outline, color: ink),
                  ),
                  title: Text(
                    '${m['display_name']}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    m['role'] == 'owner' ? 'Family owner' : 'Family member',
                  ),
                  trailing: store.isOwner && m['role'] != 'owner'
                      ? IconButton(
                          tooltip: 'Remove ${m['display_name']}',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: busy
                              ? null
                              : () async {
                                  if (await confirm(
                                    'Remove ${m['display_name']}?',
                                    'They will lose access to this family’s records. Replace the invite code too if they should not rejoin.',
                                  )) {
                                    await action(
                                      () => store.removeMember(m['user_id']),
                                      'Member removed',
                                    );
                                  }
                                },
                        )
                      : null,
                ),
              )
              .toList(),
        ),
      ),
    ] else
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            note(
              'Sign in to create or join a shared family ledger. This phone’s entries stay separate and are not uploaded automatically.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: store.client == null || googlePending || busy
                  ? null
                  : googleSignIn,
              icon: const Icon(Icons.account_circle_outlined),
              label: const Text('Continue with Google'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: store.client == null || googlePending || busy
                  ? null
                  : emailForm,
              icon: const Icon(Icons.email_outlined),
              label: const Text('Sign in with email'),
            ),
          ],
        ),
      ),
    title('Default prices'),
    note(
      'Optional. Set a usual price once, or enter it when adding a delivery.',
    ),
    const SizedBox(height: 12),
    ...['milk', 'water'].map(
      (s) => card(
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(serviceIcon(s), color: s == 'milk' ? orange : blue),
          title: Text(
            serviceName(s),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            store.settings.rate(s) == 0
                ? 'No default price set'
                : '${money(store.settings.rate(s))} per ${s == 'milk' ? 'litre' : 'can'}',
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: busy ? null : () => priceForm(s),
        ),
      ),
    ),
    card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Export this month'),
            subtitle: Text(DateFormat('MMMM yyyy').format(month)),
            onTap: exportCsv,
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('More options'),
            children: [
              if (store.cloud && store.isOwner)
                ListTile(
                  title: const Text('Replace invite code'),
                  subtitle: const Text('The current code will stop working'),
                  onTap: busy
                      ? null
                      : () async {
                          if (await confirm(
                            'Replace family code?',
                            'Existing members keep access. Share the new code with anyone you want to invite.',
                          )) {
                            await action(
                              store.rotateInvite,
                              'New invite code ready',
                            );
                          }
                        },
                ),
              if (store.cloud && !store.isOwner)
                ListTile(
                  title: const Text('Leave this family'),
                  onTap: busy
                      ? null
                      : () async {
                          if (await confirm(
                            'Leave this family?',
                            'You will lose access until you join again. The family’s records are kept.',
                          )) {
                            await action(
                              store.leaveFamily,
                              'You left the family',
                            );
                          }
                        },
                ),
              if (!store.cloud &&
                  store.hasOlderLedger &&
                  store.entries.isEmpty &&
                  store.payments.isEmpty)
                ListTile(
                  title: const Text('Restore older local records'),
                  onTap: busy
                      ? null
                      : () async {
                          if (await confirm(
                            'Restore older records?',
                            'This also brings back any sample entries from the older app.',
                          )) {
                            await action(
                              store.restoreOlderLedger,
                              'Older records restored',
                            );
                          }
                        },
                ),
              if (!store.connected)
                ListTile(
                  title: const Text('Clear this phone’s records'),
                  onTap: busy
                      ? null
                      : () async {
                          if (await confirm(
                            'Clear local records?',
                            'Export anything you want to keep first. Local deliveries and payments will be removed.',
                          )) {
                            await action(
                              store.startFresh,
                              'Local records cleared',
                            );
                          }
                        },
                ),
              if (store.connected)
                ListTile(
                  title: const Text('Sign out'),
                  subtitle: const Text('Shared family records are kept'),
                  onTap: busy ? null : () => action(store.signOut),
                ),
            ],
          ),
        ],
      ),
    ),
  ]);
  Future<void> shareInvite() async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          text:
              'Join our HydraMilk family. Open HydraMilk, sign in, tap Join a family, and enter code ${store.inviteCode}. Keep this code private.',
          sharePositionOrigin: shareOrigin(),
        ),
      );
    } catch (_) {
      message('Could not open sharing. Use Copy code instead.');
    }
  }

  Rect? shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  Future<bool> confirm(String text, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(text),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> sheet(Widget child) async => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: paper,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: child,
      ),
    ),
  );
  Future<DateTime?> selectDate(DateTime initial, {bool payment = false}) =>
      showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100, 12, 31),
        helpText: payment ? 'DATE YOU PAID' : 'DELIVERY DATE',
        fieldLabelText: 'Date (DD/MM/YYYY)',
        fieldHintText: 'DD/MM/YYYY',
      );
  DateTime newEntryDate() {
    final now = DateUtils.dateOnly(DateTime.now());
    if (month.year == now.year && month.month == now.month ||
        month.isAfter(now)) {
      return now;
    }
    return DateTime(
      month.year,
      month.month,
      math.min(now.day, DateTime(month.year, month.month + 1, 0).day),
    );
  }

  Widget dateButton(String label, DateTime date, VoidCallback? onTap) =>
      OutlinedButton(
        key: ValueKey(label),
        onPressed: onTap,
        child: Row(
          children: [
            const Icon(Icons.calendar_month_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontSize: 14, color: muted),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${fullDate(date)} · ${DateFormat('EEEE').format(date)}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.edit_calendar_outlined, size: 20),
          ],
        ),
      );
  Future<void> entryForm(
    String service, {
    Delivery? existing,
    DateTime? initialDate,
  }) async {
    lastActionError = null;
    DateTime date = DateTime.parse(
      existing?.date ?? dayKey(initialDate ?? newEntryDate()),
    );
    final quantity = TextEditingController(
      text: quantityText(
        existing?.quantityMilli ?? store.settings.quantity(service),
      ),
    );
    final previousRate = existing?.ratePaise ?? store.suggestedRate(service);
    final price = TextEditingController(
      text: previousRate == 0 ? '' : (previousRate / 100).toStringAsFixed(2),
    );
    final memo = TextEditingController(text: existing?.note ?? '');
    String status = existing?.status ?? 'delivered';
    bool saving = false;
    final form = GlobalKey<FormState>();
    final id = existing?.id ?? uuid.v4();
    await sheet(
      ControllerOwner(
        controllers: [quantity, price, memo],
        child: StatefulBuilder(
          builder: (ctx, update) {
            final amount = status == 'skipped'
                ? 0
                : amountFor(
                    parseScaled(quantity.text, 1000),
                    parseScaled(price.text, 100),
                  );
            return Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${existing == null ? 'Add' : 'Edit'} ${serviceName(service).toLowerCase()}',
                    style: const TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 18),
                  dateButton(
                    'Delivery date',
                    date,
                    saving
                        ? null
                        : () async {
                            final selected = await selectDate(date);
                            if (selected != null && ctx.mounted) {
                              update(() => date = selected);
                            }
                          },
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => update(
                                () => date = DateUtils.dateOnly(DateTime.now()),
                              ),
                        child: const Text('Today'),
                      ),
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => update(
                                () => date = DateUtils.dateOnly(
                                  DateTime.now(),
                                ).subtract(const Duration(days: 1)),
                              ),
                        child: const Text('Yesterday'),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Received'),
                        selected: status == 'delivered',
                        onSelected: saving
                            ? null
                            : (_) => update(() => status = 'delivered'),
                      ),
                      ChoiceChip(
                        label: const Text('Not received'),
                        selected: status == 'skipped',
                        onSelected: saving
                            ? null
                            : (_) => update(() => status = 'skipped'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (status == 'delivered') ...[
                    Text(
                      'Quantity (${unit(service)})',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children:
                          (service == 'milk'
                                  ? [500, 1000, 1500, 2000]
                                  : [1000, 2000, 3000, 5000])
                              .map(
                                (q) => ChoiceChip(
                                  label: Text(
                                    '${quantityText(q)} ${unit(service)}',
                                  ),
                                  selected: quantity.text == quantityText(q),
                                  onSelected: saving
                                      ? null
                                      : (_) => update(
                                          () => quantity.text = quantityText(q),
                                        ),
                                  selectedColor: peach.withValues(alpha: .6),
                                ),
                              )
                              .toList(),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: quantity,
                      enabled: !saving,
                      style: const TextStyle(fontSize: 19),
                      decoration: InputDecoration(
                        labelText: 'Quantity (${unit(service)})',
                        hintText: 'Choose above or type a quantity',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => update(() {}),
                      validator: (value) => numberError(value, precision: 3),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: price,
                      enabled: !saving,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      style: const TextStyle(fontSize: 19),
                      decoration: InputDecoration(
                        labelText:
                            'Price per ${service == 'milk' ? 'litre' : 'can'} (${store.settings.currency})',
                        hintText: 'Enter your supplier’s price',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => update(() {}),
                      validator: (value) => numberError(value),
                    ),
                    const SizedBox(height: 16),
                  ] else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: note(
                        'No delivery on this date. No charge will be added.',
                      ),
                    ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Add a note (optional)'),
                    children: [
                      TextFormField(
                        controller: memo,
                        enabled: !saving,
                        maxLength: 240,
                        decoration: const InputDecoration(labelText: 'Note'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  card(
                    amountRow('Entry amount', amount, strong: true),
                    color: const Color(0xFFFFEADC),
                  ),
                  formError(),
                  FilledButton(
                    key: const ValueKey('save-entry'),
                    onPressed: saving
                        ? null
                        : () async {
                            if (!form.currentState!.validate()) return;
                            update(() => saving = true);
                            final entry = Delivery(
                              id: id,
                              service: service,
                              date: dayKey(date),
                              quantityMilli: math.max(
                                1,
                                parseScaled(quantity.text, 1000),
                              ),
                              ratePaise: status == 'skipped'
                                  ? 0
                                  : parseScaled(price.text, 100),
                              status: status,
                              note: memo.text.trim(),
                            );
                            final ok = await action(
                              () => store.saveDelivery(entry),
                              '${serviceName(service)} saved for ${fullDate(date)}',
                            );
                            if (ok && ctx.mounted) {
                              setState(() {
                                month = DateTime(date.year, date.month);
                                statusFilter = 'All';
                              });
                              Navigator.pop(ctx);
                            } else if (ctx.mounted) {
                              update(() => saving = false);
                            }
                          },
                    child: Text(
                      saving
                          ? 'Saving…'
                          : 'Save ${serviceName(service).toLowerCase()}',
                    ),
                  ),
                  if (existing != null)
                    TextButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              if (await confirm(
                                'Delete this entry?',
                                'The bill and paid/unpaid status will be recalculated. Payment records are kept.',
                              )) {
                                update(() => saving = true);
                                final ok = await action(
                                  () => store.deleteDelivery(existing.id),
                                  'Entry deleted',
                                );
                                if (ok && ctx.mounted) {
                                  Navigator.pop(ctx);
                                } else if (ctx.mounted) {
                                  update(() => saving = false);
                                }
                              }
                            },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete entry'),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  int parseScaled(String text, int scale) {
    final value = text.trim();
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(value)) return 0;
    final parts = value.split('.'), places = scale == 1000 ? 3 : 2;
    final whole = int.tryParse(parts[0]);
    if (whole == null || whole > 1000000) return 0;
    final decimal = parts.length > 1
        ? parts[1].padRight(places, '0').substring(0, places)
        : '0';
    return whole * scale + int.parse(decimal);
  }

  String? numberError(
    String? value, {
    int precision = 2,
    bool allowZero = false,
  }) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Please enter an amount';
    if (!RegExp('^\\d+(\\.\\d{1,$precision})?\$').hasMatch(text)) {
      return 'Use numbers with up to $precision decimal places';
    }
    final number = double.tryParse(text);
    if (number == null || !number.isFinite || number > 1000000) {
      return 'Enter a number up to 1,000,000';
    }
    if (number < 0 || (!allowZero && number == 0)) {
      return 'Enter a number greater than zero';
    }
    return null;
  }

  Future<void> paymentForm(String service) async {
    lastActionError = null;
    final billingMonth = DateTime(month.year, month.month);
    final remaining = math.max(
      0,
      store.total(billingMonth, service) - store.paid(billingMonth, service),
    );
    final amount = TextEditingController(
      text: remaining == 0 ? '' : (remaining / 100).toStringAsFixed(2),
    );
    DateTime date = DateUtils.dateOnly(DateTime.now());
    final form = GlobalKey<FormState>();
    bool saving = false;
    final id = uuid.v4();
    await sheet(
      ControllerOwner(
        controllers: [amount],
        child: StatefulBuilder(
          builder: (ctx, update) => Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Record payment',
                  style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Text(
                  '${serviceName(service)} bill · ${DateFormat('MMMM yyyy').format(billingMonth)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                note(
                  'Record money you have already paid to your supplier. HydraMilk does not transfer money.',
                ),
                const SizedBox(height: 20),
                dateButton(
                  'Payment date',
                  date,
                  saving
                      ? null
                      : () async {
                          final selected = await selectDate(
                            date,
                            payment: true,
                          );
                          if (selected != null && ctx.mounted) {
                            update(() => date = selected);
                          }
                        },
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: amount,
                  enabled: !saving,
                  decoration: InputDecoration(
                    labelText: 'Amount paid (${store.settings.currency})',
                  ),
                  style: const TextStyle(fontSize: 22),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (value) => numberError(value),
                ),
                const SizedBox(height: 22),
                formError(),
                FilledButton(
                  key: const ValueKey('save-payment'),
                  onPressed: saving
                      ? null
                      : () async {
                          if (!form.currentState!.validate()) return;
                          update(() => saving = true);
                          final ok = await action(
                            () => store.savePayment(
                              Payment(
                                id: id,
                                service: service,
                                month: dayKey(billingMonth),
                                date: dayKey(date),
                                amount: parseScaled(amount.text, 100),
                              ),
                            ),
                            'Payment saved. Paid/unpaid status updated.',
                          );
                          if (ok && ctx.mounted) {
                            Navigator.pop(ctx);
                          } else if (ctx.mounted) {
                            update(() => saving = false);
                          }
                        },
                  child: Text(saving ? 'Saving…' : 'Save payment'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> familyForm({bool join = false}) async {
    lastActionError = null;
    final person = TextEditingController();
    final name = TextEditingController();
    final form = GlobalKey<FormState>();
    bool saving = false;
    await sheet(
      ControllerOwner(
        controllers: [person, name],
        child: StatefulBuilder(
          builder: (ctx, update) => Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  join ? 'Join a family' : 'Create a family',
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const ValueKey('member-name'),
                  controller: person,
                  enabled: !saving,
                  maxLength: 60,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Your name',
                    hintText: 'What should your family call you?',
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Enter your name' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  key: const ValueKey('family-name-code'),
                  controller: name,
                  enabled: !saving,
                  maxLength: join ? 20 : 60,
                  textCapitalization: join
                      ? TextCapitalization.characters
                      : TextCapitalization.words,
                  autocorrect: !join,
                  decoration: InputDecoration(
                    labelText: join ? 'Family code' : 'Family name',
                    hintText: join
                        ? 'Paste the code shared with you'
                        : 'e.g. Sharma family',
                  ),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? (join
                            ? 'Enter your family code'
                            : 'Enter a family name')
                      : null,
                ),
                if (join)
                  note(
                    'Use the code from Family → Copy code on the first person’s phone.',
                  ),
                const SizedBox(height: 20),
                formError(),
                FilledButton(
                  key: const ValueKey('save-family'),
                  onPressed: saving
                      ? null
                      : () async {
                          if (!form.currentState!.validate()) return;
                          update(() => saving = true);
                          final ok = await action(
                            () => join
                                ? store.joinFamily(
                                    name.text,
                                    person.text.trim(),
                                  )
                                : store.createFamily(
                                    name.text.trim(),
                                    person.text.trim(),
                                  ),
                            join
                                ? 'You joined your family'
                                : 'Family created. Share your code from the Family tab.',
                          );
                          // Close after a successful server operation even if reloading failed;
                          // the main retry screen must handle recovery, never create duplicates.
                          if ((ok || !store.familyLoaded) && ctx.mounted) {
                            Navigator.pop(ctx);
                            if (mounted) setState(() => tab = 2);
                          } else if (ctx.mounted) {
                            update(() => saving = false);
                          }
                        },
                  child: Text(
                    saving
                        ? 'Please wait…'
                        : join
                        ? 'Join family'
                        : 'Create family',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> priceForm(String service) async {
    lastActionError = null;
    final current = store.settings;
    final rate = TextEditingController(
      text: current.rate(service) == 0
          ? ''
          : (current.rate(service) / 100).toStringAsFixed(2),
    );
    final quantity = TextEditingController(
      text: quantityText(current.quantity(service)),
    );
    final form = GlobalKey<FormState>();
    bool saving = false;
    await sheet(
      ControllerOwner(
        controllers: [rate, quantity],
        child: StatefulBuilder(
          builder: (ctx, update) => Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${serviceName(service)} defaults',
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                note(
                  'These apply to new entries. Earlier bills keep their original prices.',
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: rate,
                  enabled: !saving,
                  decoration: InputDecoration(
                    labelText:
                        'Price per ${service == 'milk' ? 'litre' : 'can'} (${current.currency})',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) => numberError(v, allowZero: true),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: quantity,
                  enabled: !saving,
                  decoration: InputDecoration(
                    labelText: 'Usual quantity (${unit(service)})',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) => numberError(v, precision: 3),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!form.currentState!.validate()) return;
                          update(() => saving = true);
                          final next = Preferences.fromJson(current.toJson());
                          if (service == 'milk') {
                            next.milkRate = parseScaled(rate.text, 100);
                            next.milkQuantity = parseScaled(
                              quantity.text,
                              1000,
                            );
                          } else {
                            next.waterRate = parseScaled(rate.text, 100);
                            next.waterQuantity = parseScaled(
                              quantity.text,
                              1000,
                            );
                          }
                          final ok = await action(
                            () => store.saveSettings(next),
                            'Defaults saved',
                          );
                          if (ok && ctx.mounted) {
                            Navigator.pop(ctx);
                          } else if (ctx.mounted) {
                            update(() => saving = false);
                          }
                        },
                  child: Text(saving ? 'Saving…' : 'Save defaults'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> emailForm() async {
    lastActionError = null;
    final email = TextEditingController(), password = TextEditingController();
    final form = GlobalKey<FormState>();
    bool signup = false, saving = false, visible = false;
    await sheet(
      ControllerOwner(
        controllers: [email, password],
        child: StatefulBuilder(
          builder: (ctx, update) => Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  signup ? 'Create account' : 'Sign in with email',
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: email,
                  enabled: !saving,
                  autofillHints: const [AutofillHints.email],
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: (v) =>
                      v != null &&
                          RegExp(
                            r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                          ).hasMatch(v.trim())
                      ? null
                      : 'Enter a valid email',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: password,
                  enabled: !saving,
                  obscureText: !visible,
                  autofillHints: [
                    signup ? AutofillHints.newPassword : AutofillHints.password,
                  ],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    suffixIcon: IconButton(
                      tooltip: visible ? 'Hide password' : 'Show password',
                      onPressed: () => update(() => visible = !visible),
                      icon: Icon(
                        visible
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                  validator: (v) => signup
                      ? ((v?.length ?? 0) >= 8
                            ? null
                            : 'Use at least 8 characters')
                      : ((v?.isNotEmpty ?? false)
                            ? null
                            : 'Enter your password'),
                ),
                const SizedBox(height: 20),
                formError(),
                FilledButton(
                  key: const ValueKey('email-submit'),
                  onPressed: saving
                      ? null
                      : () async {
                          if (!form.currentState!.validate()) return;
                          update(() => saving = true);
                          final ok = await action(() async {
                            if (signup) {
                              await store.client!.auth.signUp(
                                email: email.text.trim(),
                                password: password.text,
                                emailRedirectTo: kIsWeb
                                    ? Uri.base
                                          .replace(query: '', fragment: '')
                                          .toString()
                                    : authCallback,
                              );
                            } else {
                              await store.client!.auth.signInWithPassword(
                                email: email.text.trim(),
                                password: password.text,
                              );
                            }
                            if (store.connected) {
                              await store.refresh();
                            } else {
                              message(
                                'Check your email to confirm your account, then return to HydraMilk.',
                              );
                            }
                          });
                          if (ok && ctx.mounted) {
                            Navigator.pop(ctx);
                            if (mounted) setState(() => tab = 0);
                          } else if (ctx.mounted) {
                            update(() => saving = false);
                          }
                        },
                  child: Text(
                    saving
                        ? 'Please wait…'
                        : signup
                        ? 'Create account'
                        : 'Sign in',
                  ),
                ),
                TextButton(
                  onPressed: saving
                      ? null
                      : () => update(() => signup = !signup),
                  child: Text(
                    signup
                        ? 'Already have an account? Sign in'
                        : 'New here? Create an account',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> exportCsv() async {
    String cell(Object value) {
      var s = '$value';
      if (RegExp(r'^\s*[=+\-@]|^[\t\r\n]').hasMatch(s)) s = "'$s";
      return '"${s.replaceAll('"', '""')}"';
    }

    final rows = <List<Object>>[
      [
        'HydraMilk',
        store.settings.name,
        DateFormat('MMMM yyyy').format(month),
        store.settings.currency,
      ],
      ['Month register'],
      [
        'Date',
        'Milk (L)',
        'Milk amount',
        'Milk status',
        'Milk paid',
        'Water (cans)',
        'Water amount',
        'Water status',
        'Water paid',
      ],
      ...store
          .daysForMonth(month)
          .map(
            (day) => [
              dayKey(day.date),
              day.milk.hasEntries ? quantityText(day.milk.quantityMilli) : '',
              day.milk.hasEntries
                  ? (day.milk.amount / 100).toStringAsFixed(2)
                  : '',
              day.milk.paymentStatus,
              day.milk.hasEntries
                  ? (day.milk.paid / 100).toStringAsFixed(2)
                  : '',
              day.water.hasEntries ? quantityText(day.water.quantityMilli) : '',
              day.water.hasEntries
                  ? (day.water.amount / 100).toStringAsFixed(2)
                  : '',
              day.water.paymentStatus,
              day.water.hasEntries
                  ? (day.water.paid / 100).toStringAsFixed(2)
                  : '',
            ],
          ),
      [],
      ['Individual entries and payments'],
      [
        'Type',
        'Date',
        'Service',
        'Delivery status',
        'Quantity',
        'Unit',
        'Rate',
        'Amount',
        'Paid applied',
        'Payment status',
        'Note',
      ],
      ...store
          .forMonth(month)
          .map(
            (e) => [
              'Delivery',
              e.date,
              e.service,
              e.status,
              quantityText(e.quantityMilli),
              unit(e.service),
              (e.ratePaise / 100).toStringAsFixed(2),
              (e.amount / 100).toStringAsFixed(2),
              (store.paidForEntry(e) / 100).toStringAsFixed(2),
              e.amount == 0
                  ? 'No charge'
                  : store.paidForEntry(e) >= e.amount
                  ? 'Paid'
                  : store.paidForEntry(e) > 0
                  ? 'Part paid'
                  : 'Unpaid',
              e.note,
            ],
          ),
      ...store.payments
          .where((p) => p.month == dayKey(month))
          .map(
            (p) => [
              'Payment',
              p.date,
              p.service,
              '',
              '',
              '',
              '',
              (p.amount / 100).toStringAsFixed(2),
              '',
              'Paid',
              p.note,
            ],
          ),
      [],
      ['Service', 'Billed', 'Paid', 'Balance'],
      ...['milk', 'water'].map(
        (s) => [
          s,
          (store.total(month, s) / 100).toStringAsFixed(2),
          (store.paid(month, s) / 100).toStringAsFixed(2),
          ((store.total(month, s) - store.paid(month, s)) / 100)
              .toStringAsFixed(2),
        ],
      ),
    ];
    final csv = '\uFEFF${rows.map((r) => r.map(cell).join(',')).join('\r\n')}';
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(csv)),
              mimeType: 'text/csv',
            ),
          ],
          fileNameOverrides: [
            'HydraMilk-${DateFormat('yyyy-MM').format(month)}.csv',
          ],
          sharePositionOrigin: shareOrigin(),
        ),
      );
    } catch (_) {
      message('Could not open export. Please try again.');
    }
  }
}

class ControllerOwner extends StatefulWidget {
  const ControllerOwner({
    super.key,
    required this.controllers,
    required this.child,
  });
  final List<TextEditingController> controllers;
  final Widget child;
  @override
  State<ControllerOwner> createState() => _ControllerOwnerState();
}

class _ControllerOwnerState extends State<ControllerOwner> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class MonthTableHeader extends SliverPersistentHeaderDelegate {
  MonthTableHeader({required this.height, required this.child});
  final double height;
  final Widget child;
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox(
    height: height,
    child: Material(color: paper, child: child),
  );
  @override
  bool shouldRebuild(covariant MonthTableHeader oldDelegate) =>
      oldDelegate.height != height || oldDelegate.child != child;
}
