import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';

const uuid = Uuid();

class LedgerStore extends ChangeNotifier {
  LedgerStore(this.prefs, {this.client});
  final SharedPreferences prefs;
  final SupabaseClient? client;
  Preferences settings = Preferences();
  List<Delivery> entries = [];
  List<Payment> payments = [];
  List<Map<String, dynamic>> members = [];
  String? familyId, inviteCode;
  bool demo = false;
  bool syncPending = false;
  bool familyLoaded = false;
  DateTime? lastSyncedAt;
  Future<void>? _refreshFuture;
  int _generation = 0;
  bool get refreshing => _refreshFuture != null;

  bool get isOwner => members.any(
    (m) => m['user_id'] == client?.auth.currentUser?.id && m['role'] == 'owner',
  );
  bool get localModeChosen => prefs.getBool('local_mode_chosen') ?? false;
  bool get hasOlderLedger => prefs.containsKey('older_local_ledger');
  Future<void> chooseLocalMode() async {
    if (!await prefs.setBool('local_mode_chosen', true)) {
      throw Exception('Could not save your choice. Please try again.');
    }
    notifyListeners();
  }

  int suggestedRate(String service) {
    if (settings.rate(service) > 0) return settings.rate(service);
    final previous =
        entries
            .where(
              (e) =>
                  e.service == service &&
                  e.status == 'delivered' &&
                  e.ratePaise > 0,
            )
            .toList()
          ..sort((a, b) {
            final date = b.date.compareTo(a.date);
            return date != 0 ? date : b.id.compareTo(a.id);
          });
    return previous.isEmpty ? 0 : previous.first.ratePaise;
  }

  bool get connected => client?.auth.currentSession != null;
  bool get cloud => familyId != null;
  Future<void> load() async {
    if (connected) {
      await refresh();
      return;
    }
    final raw = prefs.getString('local_ledger');
    if (raw == null) {
      settings = Preferences();
      entries = [];
      payments = [];
      demo = false;
      await persist();
    } else {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['demo'] == true) {
        // Older versions mixed sample and user-added entries. Keep a recoverable
        // copy before opening an empty ledger; never discard that older data.
        if (!await prefs.setString('older_local_ledger', raw)) {
          throw Exception('Could not back up the older ledger.');
        }
        settings = Preferences();
        entries = [];
        payments = [];
        demo = false;
        await prefs.remove('local_mode_chosen');
        await persist();
      } else {
        readLocal(j);
      }
    }
    notifyListeners();
  }

  void readLocal(Map<String, dynamic> j) {
    settings = Preferences.fromJson(Map<String, dynamic>.from(j['settings']));
    entries = (j['entries'] as List)
        .map((e) => Delivery.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    payments = (j['payments'] as List)
        .map((e) => Payment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    demo = false;
  }

  Future<void> restoreOlderLedger() async {
    if (connected || cloud) {
      throw Exception('Sign out before restoring local records.');
    }
    final raw = prefs.getString('older_local_ledger');
    if (raw == null) return;
    final oldSettings = settings;
    final oldEntries = entries;
    final oldPayments = payments;
    // Restoration is only offered on an empty ledger, so new entries cannot be
    // overwritten by a restore from the old version.
    if (entries.isNotEmpty || payments.isNotEmpty) {
      throw Exception('Export or keep your current records before restoring.');
    }
    readLocal(jsonDecode(raw) as Map<String, dynamic>);
    try {
      await persist();
    } catch (_) {
      settings = oldSettings;
      entries = oldEntries;
      payments = oldPayments;
      rethrow;
    }
  }

  Future<void> persist() async {
    if (!cloud) {
      final saved = await prefs.setString(
        'local_ledger',
        jsonEncode({
          'settings': settings.toJson(),
          'entries': entries.map((e) => e.toJson()).toList(),
          'payments': payments.map((e) => e.toJson()).toList(),
          'demo': demo,
        }),
      );
      if (!saved) {
        throw Exception('Could not save on this device.');
      }
    }
    notifyListeners();
  }

  Future<void> refresh() {
    if (_refreshFuture != null) return _refreshFuture!;
    final generation = _generation;
    final completer = Completer<void>();
    _refreshFuture = completer.future;
    notifyListeners();
    unawaited(() async {
      try {
        await _readFamily();
        completer.complete();
      } catch (error, stack) {
        if (generation == _generation && connected) syncPending = true;
        completer.completeError(error, stack);
      } finally {
        _refreshFuture = null;
        notifyListeners();
      }
    }());
    return completer.future;
  }

  Future<void> _readFamily() async {
    if (!connected) return;
    final userId = client!.auth.currentUser!.id;
    final generation = _generation;
    bool stillCurrent() =>
        generation == _generation && client!.auth.currentUser?.id == userId;
    final memberships = await client!
        .from('memberships')
        .select('family_id')
        .eq('user_id', userId);
    if (!stillCurrent()) return;
    if (memberships.isEmpty) {
      familyId = null;
      inviteCode = null;
      entries = [];
      payments = [];
      members = [];
      settings = Preferences();
      demo = false;
      familyLoaded = true;
      syncPending = false;
      lastSyncedAt = DateTime.now();
      return;
    }
    final id = memberships.first['family_id'] as String;
    final family = await client!
        .from('families')
        .select()
        .eq('id', id)
        .single();
    final rows = await allRows('deliveries', id);
    final paid = await allRows('payments', id);
    final people = await client!
        .from('memberships')
        .select('user_id, display_name, role')
        .eq('family_id', id);
    if (!stillCurrent()) return;
    familyId = id;
    inviteCode = family['invite_code'];
    settings = Preferences.fromJson(
      Map<String, dynamic>.from(family['settings']),
    );
    entries = rows.map((e) => Delivery.fromJson(e)).toList();
    payments = paid.map((e) => Payment.fromJson(e)).toList();
    members = people;
    demo = false;
    familyLoaded = true;
    syncPending = false;
    lastSyncedAt = DateTime.now();
  }

  Future<List<Map<String, dynamic>>> allRows(String table, String id) async {
    final rows = <Map<String, dynamic>>[];
    for (int start = 0; ; start += 500) {
      final page = await client!
          .from(table)
          .select()
          .eq('family_id', id)
          .order('date', ascending: false)
          .order('id')
          .range(start, start + 499);
      rows.addAll(page);
      if (page.length < 500) {
        break;
      }
    }
    return rows;
  }

  Future<void> syncAfterWrite() async {
    try {
      // An older background read must finish before a read of the new write.
      if (_refreshFuture != null) {
        try {
          await _refreshFuture;
        } catch (_) {}
      }
      await refresh();
    } catch (_) {
      syncPending = true;
      notifyListeners();
    }
  }

  Future<void> removeMember(String userId) async {
    await client!.rpc('remove_family_member', params: {'p_user_id': userId});
    members.removeWhere((m) => m['user_id'] == userId);
    await syncAfterWrite();
  }

  Future<void> leaveFamily() async {
    await client!.rpc('leave_family');
    _generation++;
    familyLoaded = true;
    syncPending = false;
    familyId = null;
    entries = [];
    payments = [];
    members = [];
    inviteCode = null;
    settings = Preferences();
    notifyListeners();
  }

  Future<void> saveDelivery(Delivery e) async {
    requireWritable();
    if (connected && !cloud) {
      throw Exception('Create or join a family first.');
    }
    if (cloud) {
      await client!.from('deliveries').upsert({
        ...e.toJson(),
        'family_id': familyId,
      });
      entries.removeWhere((x) => x.id == e.id);
      entries.add(e);
      await syncAfterWrite();
    } else {
      final old = List<Delivery>.from(entries);
      entries.removeWhere((x) => x.id == e.id);
      entries.add(e);
      try {
        await persist();
      } catch (_) {
        entries = old;
        rethrow;
      }
    }
    notifyListeners();
  }

  Future<void> deleteDelivery(String id) async {
    requireWritable();
    if (cloud) {
      await client!
          .from('deliveries')
          .delete()
          .eq('id', id)
          .eq('family_id', familyId!);
      entries.removeWhere((e) => e.id == id);
      await syncAfterWrite();
    } else {
      final old = List<Delivery>.from(entries);
      entries.removeWhere((e) => e.id == id);
      try {
        await persist();
      } catch (_) {
        entries = old;
        rethrow;
      }
    }
    notifyListeners();
  }

  Future<void> savePayment(Payment p) async {
    requireWritable();
    if (cloud) {
      await client!.rpc(
        'record_payment',
        params: {
          'p_id': p.id,
          'p_service': p.service,
          'p_month': p.month,
          'p_date': p.date,
          'p_amount': p.amount,
          'p_note': p.note,
        },
      );
      payments.removeWhere((old) => old.id == p.id);
      payments.add(p);
      await syncAfterWrite();
    } else {
      final old = List<Payment>.from(payments);
      payments.removeWhere((existing) => existing.id == p.id);
      payments.add(p);
      try {
        await persist();
      } catch (_) {
        payments = old;
        rethrow;
      }
    }
    notifyListeners();
  }

  Future<void> deletePayment(String id) async {
    requireWritable();
    if (cloud) {
      await client!
          .from('payments')
          .delete()
          .eq('id', id)
          .eq('family_id', familyId!);
      payments.removeWhere((p) => p.id == id);
      await syncAfterWrite();
    } else {
      final old = List<Payment>.from(payments);
      payments.removeWhere((p) => p.id == id);
      try {
        await persist();
      } catch (_) {
        payments = old;
        rethrow;
      }
    }
  }

  Future<void> saveSettings(Preferences s) async {
    requireWritable();
    if (cloud) {
      await client!.rpc(
        'update_family_settings',
        params: {'p_settings': s.toJson()},
      );
    }
    final old = settings;
    settings = s;
    try {
      await persist();
    } catch (_) {
      settings = old;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> startFresh() async {
    final oldEntries = entries;
    final oldPayments = payments;
    final wasDemo = demo;
    entries = [];
    payments = [];
    demo = false;
    try {
      await persist();
    } catch (_) {
      entries = oldEntries;
      payments = oldPayments;
      demo = wasDemo;
      rethrow;
    }
  }

  Future<void> createFamily(String name, String member) async {
    await client!.rpc(
      'create_family',
      params: {'p_name': name, 'p_display_name': member},
    );
    familyLoaded = false;
    await refreshAfterMembershipWrite();
  }

  Future<void> joinFamily(String code, String member) async {
    await client!.rpc(
      'join_family',
      params: {
        'p_code': code.replaceAll(RegExp(r'\s+'), '').toUpperCase(),
        'p_display_name': member,
      },
    );
    familyLoaded = false;
    await refreshAfterMembershipWrite();
  }

  Future<void> refreshAfterMembershipWrite() async {
    if (_refreshFuture != null) {
      try {
        await _refreshFuture;
      } catch (_) {}
    }
    await refresh();
  }

  Future<void> rotateInvite() async {
    await client!.rpc('rotate_invite');
    await syncAfterWrite();
  }

  void requireWritable() {
    if (connected && !cloud) {
      throw StateError('Create or join your family first.');
    }
    if (cloud && !connected) {
      throw StateError('Sign in again to save family records.');
    }
  }

  Future<void> resetAfterSignOut() async {
    _generation++;
    familyLoaded = false;
    syncPending = false;
    lastSyncedAt = null;
    familyId = null;
    inviteCode = null;
    members = [];
    await prefs.remove('local_mode_chosen');
    await load();
  }

  Future<void> signOut() async {
    await client!.auth.signOut();
    await prefs.remove('local_mode_chosen');
    await resetAfterSignOut();
  }

  // Monthly supplier payments are allocated to deliveries in a stable oldest-
  // first order. This is derived, so edits/deletes/retries cannot leave stale
  // boolean paid flags or double-count a month's payments.
  Map<String, int> paidAllocation(DateTime month) {
    final result = <String, int>{};
    for (final service in ['milk', 'water']) {
      final ordered = forMonth(month, service)
        ..sort((a, b) {
          final date = a.date.compareTo(b.date);
          return date != 0 ? date : a.id.compareTo(b.id);
        });
      int remaining = paid(month, service);
      for (final entry in ordered) {
        final applied = math.min(math.max(0, remaining), entry.amount);
        result[entry.id] = applied;
        remaining -= applied;
      }
    }
    return result;
  }

  int paidForEntry(Delivery entry) =>
      paidAllocation(DateTime.parse(entry.date))[entry.id] ?? 0;

  List<LedgerDay> daysForMonth(DateTime month) {
    final rows = forMonth(month);
    final allocation = paidAllocation(month);
    final grouped = <String, List<Delivery>>{};
    for (final entry in rows) {
      grouped
          .putIfAbsent('${entry.date}:${entry.service}', () => [])
          .add(entry);
    }
    return List.generate(DateTime(month.year, month.month + 1, 0).day, (index) {
      final date = DateTime(month.year, month.month, index + 1);
      ServiceDay group(String service) {
        final records = List<Delivery>.unmodifiable(
          grouped['${dayKey(date)}:$service'] ?? <Delivery>[],
        );
        return ServiceDay(
          service: service,
          entries: records,
          paid: records.fold(0, (sum, e) => sum + (allocation[e.id] ?? 0)),
        );
      }

      return LedgerDay(date: date, milk: group('milk'), water: group('water'));
    });
  }

  List<Delivery> forMonth(DateTime m, [String? service]) =>
      entries
          .where(
            (e) =>
                e.date.startsWith(dayKey(m).substring(0, 7)) &&
                (service == null || e.service == service),
          )
          .toList()
        ..sort((a, b) {
          final date = b.date.compareTo(a.date);
          return date != 0 ? date : b.id.compareTo(a.id);
        });
  int total(DateTime m, [String? service]) =>
      forMonth(m, service).fold(0, (s, e) => s + e.amount);
  int paid(DateTime m, String service) => payments
      .where(
        (p) =>
            p.month == dayKey(DateTime(m.year, m.month)) &&
            p.service == service,
      )
      .fold(0, (s, p) => s + p.amount);
}
