import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:peach_ledger/store.dart';
import 'package:peach_ledger/models.dart';

// Exercises the real Dart Auth/PostgREST client and store against an in-memory
// HTTP server. Actual database authorization is covered by isolation.sql.
class FamilyServer {
  final memberships = <String, Map<String, dynamic>>{};
  final families = <String, Map<String, dynamic>>{};
  final deliveries = <String, Map<String, dynamic>>{};
  final payments = <String, Map<String, dynamic>>{};
  bool failNextMembershipRead = false;
  Future<void>? membershipDelay;
  int familyCreates = 0;
  int familyNumber = 0;
  String user(String email) => email.startsWith('owner')
      ? '00000000-0000-0000-0000-000000000001'
      : email.startsWith('member')
      ? '00000000-0000-0000-0000-000000000002'
      : '00000000-0000-0000-0000-000000000003';
  String token(String id) {
    String enc(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.${enc({'sub': id, 'aud': 'authenticated', 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.signature';
  }

  http.Response response(Object? data, [int status = 200]) => http.Response(
    data == null ? '' : jsonEncode(data),
    status,
    headers: {'content-type': 'application/json'},
  );
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(request.body) as Map<String, dynamic>?) ??
              <String, dynamic>{};
    if (path == '/auth/v1/token') {
      final email = body['email'] as String, id = user(email);
      return response({
        'access_token': token(id),
        'token_type': 'bearer',
        'expires_in': 3600,
        'refresh_token': 'test-refresh-$id',
        'user': {
          'id': id,
          'aud': 'authenticated',
          'role': 'authenticated',
          'email': email,
          'app_metadata': {},
          'user_metadata': {},
          'created_at': '2026-01-01T00:00:00Z',
        },
      });
    }
    if (path == '/auth/v1/logout') return response(null, 204);
    final auth =
        request.headers['Authorization'] ??
        request.headers['authorization'] ??
        '';
    final payload = auth.replaceFirst('Bearer ', '').split('.');
    final uid = payload.length == 3
        ? (jsonDecode(
                    utf8.decode(
                      base64Url.decode(base64Url.normalize(payload[1])),
                    ),
                  )
                  as Map<String, dynamic>)['sub']
              as String
        : '';
    final member = memberships[uid];
    final fid = member?['family_id'];
    if (path == '/rest/v1/rpc/create_family') {
      if (member != null) {
        return response({
          'message': 'You already belong to a family',
          'code': 'P0001',
        }, 400);
      }
      final id =
          '10000000-0000-0000-0000-${(++familyNumber).toString().padLeft(12, '0')}';
      familyCreates++;
      families[id] = {
        'id': id,
        'owner_id': uid,
        'invite_code': 'CODE${familyNumber.toString().padLeft(6, '0')}',
        'settings': Preferences(name: body['p_name']).toJson(),
      };
      memberships[uid] = {
        'user_id': uid,
        'family_id': id,
        'display_name': body['p_display_name'],
        'role': 'owner',
      };
      return response(id);
    }
    if (path == '/rest/v1/rpc/join_family') {
      if (member != null) {
        return response({
          'message': 'You already belong to a family',
          'code': 'P0001',
        }, 400);
      }
      final matches = families.values.where(
        (f) => f['invite_code'] == body['p_code'],
      );
      if (matches.isEmpty) {
        return response({
          'message': 'Invite code not found. Check it with your family.',
          'code': 'P0001',
        }, 400);
      }
      final id = matches.first['id'];
      memberships[uid] = {
        'user_id': uid,
        'family_id': id,
        'display_name': body['p_display_name'],
        'role': 'member',
      };
      return response(id);
    }
    if (path == '/rest/v1/memberships') {
      if (membershipDelay != null) await membershipDelay;
      if (failNextMembershipRead) {
        failNextMembershipRead = false;
        return response({
          'message': 'temporary unavailable',
          'code': 'XX000',
        }, 400);
      }
      if (request.url.queryParameters.containsKey('user_id')) {
        return response(
          member == null
              ? []
              : [
                  {'family_id': fid},
                ],
        );
      }
      return response(
        memberships.values.where((m) => m['family_id'] == fid).toList(),
      );
    }
    if (path == '/rest/v1/families') return response(families[fid]);
    if (path == '/rest/v1/deliveries') {
      if (request.method == 'POST') {
        deliveries[body['id']] = {...body};
        return response(null, 201);
      }
      if (request.method == 'DELETE') {
        deliveries.remove(
          request.url.queryParameters['id']?.replaceFirst('eq.', ''),
        );
        return response(null, 204);
      }
      return response(
        deliveries.values.where((e) => e['family_id'] == fid).toList(),
      );
    }
    if (path == '/rest/v1/payments') {
      return response(
        payments.values.where((p) => p['family_id'] == fid).toList(),
      );
    }
    if (path == '/rest/v1/rpc/record_payment') {
      payments.putIfAbsent(
        body['p_id'],
        () => {
          'id': body['p_id'],
          'family_id': fid,
          'service': body['p_service'],
          'billing_month': body['p_month'],
          'date': body['p_date'],
          'amount_paise': body['p_amount'],
          'note': body['p_note'],
        },
      );
      return response(null, 204);
    }
    if (path == '/rest/v1/rpc/rotate_invite') {
      families[fid]!['invite_code'] = 'NEWCODE123';
      return response('NEWCODE123');
    }
    if (path == '/rest/v1/rpc/remove_family_member') {
      memberships.remove(body['p_user_id']);
      return response(null, 204);
    }
    if (path == '/rest/v1/rpc/leave_family') {
      memberships.remove(uid);
      return response(null, 204);
    }
    return response({'message': 'Unexpected endpoint $path'}, 404);
  }

  Future<LedgerStore> open(String email, {bool registerDispose = true}) async {
    final client = SupabaseClient(
      'https://test.supabase.co',
      'public-test-key',
      httpClient: MockClient((request) async {
        final result = await handle(request);
        return http.Response.bytes(
          result.bodyBytes,
          result.statusCode,
          headers: result.headers,
          request: request,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    if (registerDispose) addTearDown(client.dispose);
    await client.auth.signInWithPassword(
      email: email,
      password: 'test-password',
    );
    final store = LedgerStore(
      await SharedPreferences.getInstance(),
      client: client,
    );
    await store.load();
    return store;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'Two accounts create/join one family, share deliveries/payments, rotate code, and revoke removed member',
    () async {
      final server = FamilyServer();
      final owner = await server.open('owner@example.com');
      expect(owner.connected, true);
      expect(owner.familyLoaded, true);
      expect(owner.cloud, false);
      await owner.createFamily('Our home', 'Parent');
      expect(owner.cloud, true);
      expect(owner.isOwner, true);
      expect(owner.settings.milkRate, 0);
      final member = await server.open('member@example.com');
      await expectLater(
        member.joinFamily('WRONG', 'Child'),
        throwsA(isA<PostgrestException>()),
      );
      expect(member.familyLoaded, true);
      expect(member.cloud, false);
      final code = owner.inviteCode!;
      await member.joinFamily(
        ' ${code.toLowerCase().substring(0, 4)} ${code.toLowerCase().substring(4)} ',
        'Child',
      );
      expect(member.familyId, owner.familyId);
      expect(member.members.length, 2);
      expect(member.isOwner, false);
      await member.saveDelivery(
        Delivery(
          id: '20000000-0000-0000-0000-000000000001',
          service: 'milk',
          date: '2026-10-19',
          quantityMilli: 1500,
          ratePaise: 6000,
        ),
      );
      await owner.refresh();
      expect(owner.entries.single.amount, 9000);
      final payment = Payment(
        id: '30000000-0000-0000-0000-000000000001',
        service: 'milk',
        month: '2026-10-01',
        date: '2026-10-20',
        amount: 9000,
      );
      await owner.savePayment(payment);
      await owner.savePayment(payment);
      await member.refresh();
      expect(member.payments.length, 1);
      expect(member.paidForEntry(member.entries.single), 9000);
      await owner.rotateInvite();
      expect(owner.inviteCode, 'NEWCODE123');
      await member.refresh();
      expect(member.inviteCode, 'NEWCODE123');
      await owner.removeMember(member.client!.auth.currentUser!.id);
      await member.refresh();
      expect(member.cloud, false);
      expect(member.familyLoaded, true);
      expect(member.inviteCode, isNull);
      expect(member.entries, isEmpty);
      expect(member.payments, isEmpty);
      await member.joinFamily('NEWCODE123', 'Child');
      await member.leaveFamily();
      expect(member.cloud, false);
      expect(member.inviteCode, isNull);
      expect(
        owner.entries.length,
        1,
        reason: 'Other member leaving must not erase family records',
      );
    },
  );
  test(
    'A reload failure after create is recoverable without creating another family',
    () async {
      final server = FamilyServer();
      final store = await server.open('owner@example.com');
      server.failNextMembershipRead = true;
      await expectLater(
        store.createFamily('Our home', 'Parent'),
        throwsA(isA<PostgrestException>()),
      );
      expect(store.familyLoaded, false);
      expect(store.syncPending, true);
      expect(server.familyCreates, 1);
      await store.refresh();
      expect(store.cloud, true);
      expect(store.familyLoaded, true);
      expect(store.syncPending, false);
      expect(server.familyCreates, 1);
    },
  );
  test(
    'Failed refresh after a saved write keeps the new entry and recovers on reload',
    () async {
      final server = FamilyServer();
      final store = await server.open('owner@example.com');
      await store.createFamily('Home', 'Parent');
      server.failNextMembershipRead = true;
      await store.saveDelivery(
        Delivery(
          id: '20000000-0000-0000-0000-000000000002',
          service: 'water',
          date: '2026-10-19',
          quantityMilli: 1000,
          ratePaise: 4000,
          status: 'skipped',
        ),
      );
      expect(store.entries.single.status, 'skipped');
      expect(store.syncPending, true);
      await store.refresh();
      expect(store.entries.length, 1);
      expect(store.entries.single.amount, 0);
      expect(store.syncPending, false);
    },
  );
  test(
    'A delayed family read cannot bring shared records back after sign-out',
    () async {
      final server = FamilyServer();
      final store = await server.open('owner@example.com');
      await store.createFamily('Home', 'Parent');
      final wait = Completer<void>();
      server.membershipDelay = wait.future;
      final pending = store.refresh();
      await Future<void>.delayed(Duration.zero);
      await store.signOut();
      wait.complete();
      await pending;
      expect(store.connected, false);
      expect(store.cloud, false);
      expect(store.members, isEmpty);
      expect(store.inviteCode, isNull);
      expect(store.localModeChosen, false);
    },
  );
  test(
    'Signing out restores only the local ledger and clears family identity',
    () async {
      final server = FamilyServer();
      final store = await server.open('owner@example.com');
      await store.createFamily('Home', 'Parent');
      await store.signOut();
      expect(store.connected, false);
      expect(store.cloud, false);
      expect(store.members, isEmpty);
      expect(store.inviteCode, isNull);
      expect(store.entries, isEmpty);
      expect(store.localModeChosen, false);
    },
  );
}
