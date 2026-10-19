import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:peach_ledger/models.dart';
import 'package:peach_ledger/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LedgerStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LedgerStore(await SharedPreferences.getInstance());
    await store.load();
    await store.startFresh();
  });
  test(
    'A fresh installation has no sample records, prices, budget, or local mode',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fresh = LedgerStore(await SharedPreferences.getInstance());
      await fresh.load();
      expect(fresh.entries, isEmpty);
      expect(fresh.payments, isEmpty);
      expect(fresh.settings.milkRate, 0);
      expect(fresh.settings.waterRate, 0);
      expect(fresh.settings.budget, 0);
      expect(fresh.demo, false);
      expect(fresh.localModeChosen, false);
      await fresh.chooseLocalMode();
      final reopened = LedgerStore(await SharedPreferences.getInstance());
      await reopened.load();
      expect(reopened.localModeChosen, true);
      expect(reopened.entries, isEmpty);
    },
  );
  test(
    'An older sample ledger is archived and can be restored without losing records',
    () async {
      await store.saveDelivery(
        Delivery(
          id: 'legacy-real-entry',
          service: 'milk',
          date: '2026-10-01',
          quantityMilli: 1000,
          ratePaise: 7200,
        ),
      );
      store.demo = true;
      await store.persist();
      final fresh = LedgerStore(await SharedPreferences.getInstance());
      await fresh.load();
      expect(fresh.entries, isEmpty);
      expect(fresh.settings.milkRate, 0);
      expect(fresh.hasOlderLedger, true);
      await fresh.restoreOlderLedger();
      expect(fresh.entries.single.id, 'legacy-real-entry');
      expect(fresh.demo, false);
      final reopened = LedgerStore(await SharedPreferences.getInstance());
      await reopened.load();
      expect(reopened.entries.single.ratePaise, 7200);
    },
  );
  test(
    'Last real prices are remembered separately for milk and water',
    () async {
      expect(store.suggestedRate('milk'), 0);
      await store.saveDelivery(
        Delivery(
          id: 'm',
          service: 'milk',
          date: '2026-10-19',
          quantityMilli: 1000,
          ratePaise: 7250,
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 'w',
          service: 'water',
          date: '2026-10-19',
          quantityMilli: 1000,
          ratePaise: 3500,
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 's',
          service: 'milk',
          date: '2026-10-20',
          quantityMilli: 1000,
          ratePaise: 0,
          status: 'skipped',
        ),
      );
      expect(store.suggestedRate('milk'), 7250);
      expect(store.suggestedRate('water'), 3500);
    },
  );
  test(
    'Paid status allocates oldest first, supports partial payments, credits, and month isolation',
    () async {
      final earlier = Delivery(
        id: 'a',
        service: 'milk',
        date: '2024-02-28',
        quantityMilli: 1000,
        ratePaise: 6000,
      );
      final later = Delivery(
        id: 'b',
        service: 'milk',
        date: '2024-02-29',
        quantityMilli: 1000,
        ratePaise: 6000,
      );
      final water = Delivery(
        id: 'w',
        service: 'water',
        date: '2024-02-28',
        quantityMilli: 1000,
        ratePaise: 4000,
      );
      final nextMonth = Delivery(
        id: 'n',
        service: 'milk',
        date: '2024-03-01',
        quantityMilli: 1000,
        ratePaise: 6000,
      );
      for (final entry in [later, earlier, water, nextMonth]) {
        await store.saveDelivery(entry);
      }
      expect(store.paidForEntry(earlier), 0);
      final payment = Payment(
        id: 'paid',
        service: 'milk',
        month: '2024-02-01',
        date: '2024-03-03',
        amount: 8000,
      );
      await store.savePayment(payment);
      await store.savePayment(payment);
      expect(
        store.payments.length,
        1,
        reason: 'A payment retry must not double count',
      );
      expect(store.paidForEntry(earlier), 6000);
      expect(store.paidForEntry(later), 2000);
      expect(store.paidForEntry(water), 0);
      expect(store.paidForEntry(nextMonth), 0);
      await store.savePayment(
        Payment(
          id: 'extra',
          service: 'milk',
          month: '2024-02-01',
          date: '2024-03-04',
          amount: 10000,
        ),
      );
      expect(store.paidForEntry(later), 6000);
      expect(
        store.paid(DateTime(2024, 2), 'milk') -
            store.total(DateTime(2024, 2), 'milk'),
        6000,
      );
      await store.deletePayment('extra');
      expect(store.paidForEntry(later), 2000);
      await store.deleteDelivery('a');
      expect(store.paidForEntry(later), 6000);
    },
  );
  test(
    'The whole-month register includes missing days, leap days, both services and multiple entries',
    () async {
      final feb = DateTime(2024, 2);
      await store.saveDelivery(
        Delivery(
          id: 'm1',
          service: 'milk',
          date: '2024-02-29',
          quantityMilli: 500,
          ratePaise: 6000,
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 'm2',
          service: 'milk',
          date: '2024-02-29',
          quantityMilli: 1000,
          ratePaise: 6000,
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 's',
          service: 'milk',
          date: '2024-02-29',
          quantityMilli: 1000,
          ratePaise: 6000,
          status: 'skipped',
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 'w',
          service: 'water',
          date: '2024-02-28',
          quantityMilli: 1000,
          ratePaise: 4000,
          status: 'skipped',
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 'other',
          service: 'milk',
          date: '2025-02-28',
          quantityMilli: 1000,
          ratePaise: 9000,
        ),
      );
      await store.savePayment(
        Payment(
          id: 'p',
          service: 'milk',
          month: '2024-02-01',
          date: '2024-03-01',
          amount: 3000,
        ),
      );
      final days = store.daysForMonth(feb);
      expect(days.length, 29);
      expect(dayKey(days.first.date), '2024-02-01');
      expect(dayKey(days.last.date), '2024-02-29');
      expect(days.first.milk.paymentStatus, 'No entry');
      expect(days.first.water.hasEntries, false);
      expect(days[27].water.paymentStatus, 'Not received');
      expect(days[27].water.amount, 0);
      expect(days[27].water.quantityMilli, 0);
      final milk = days.last.milk;
      expect(milk.entries.length, 3);
      expect(milk.receivedCount, 2);
      expect(milk.skippedCount, 1);
      expect(milk.quantityMilli, 1500);
      expect(milk.amount, 9000);
      expect(milk.paid, 3000);
      expect(milk.paymentStatus, 'Part paid');
      expect(days.last.water.paymentStatus, 'No entry');
      expect(store.daysForMonth(DateTime(2025, 2)).length, 28);
      expect(store.daysForMonth(DateTime(2026, 4)).length, 30);
      expect(store.daysForMonth(DateTime(2026, 12)).length, 31);
      expect(
        days.fold(0, (sum, day) => sum + day.milk.amount),
        store.total(feb, 'milk'),
      );
      expect(
        days.fold(0, (sum, day) => sum + day.water.amount),
        store.total(feb, 'water'),
      );
    },
  );
  test('Fractional quantities round once, in integer minor currency units', () {
    expect(amountFor(1500, 6250), 9375);
    expect(amountFor(333, 100), 33);
    expect(amountFor(5, 100), 1);
    expect(amountFor(1000000000, 100000000), 100000000000000);
    expect(quantityText(1500), '1.5');
    expect(quantityText(1000), '1');
    expect(quantityText(1), '0.001');
  });
  test(
    'Skipped days cost zero; edits and historical rates update only the entry',
    () async {
      final m = DateTime(2024, 2);
      await store.saveDelivery(
        Delivery(
          id: 'a',
          service: 'milk',
          date: '2024-02-29',
          quantityMilli: 1500,
          ratePaise: 6250,
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 'b',
          service: 'water',
          date: '2024-02-28',
          quantityMilli: 2000,
          ratePaise: 4000,
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 'c',
          service: 'milk',
          date: '2024-02-27',
          quantityMilli: 1000,
          ratePaise: 6000,
          status: 'skipped',
        ),
      );
      expect(store.total(m), 17375);
      await store.saveSettings(Preferences(milkRate: 9000));
      expect(store.total(m, 'milk'), 9375);
      await store.saveDelivery(
        Delivery(
          id: 'a',
          service: 'milk',
          date: '2024-02-29',
          quantityMilli: 1000,
          ratePaise: 6250,
        ),
      );
      expect(store.total(m), 14250);
      expect(store.entries.length, 3);
      await store.deleteDelivery('a');
      expect(store.total(m), 8000);
    },
  );
  test(
    'Years and months stay separate and local data survives restart',
    () async {
      await store.saveDelivery(
        Delivery(
          id: 'a',
          service: 'milk',
          date: '2025-12-31',
          quantityMilli: 1000,
          ratePaise: 6000,
        ),
      );
      await store.saveDelivery(
        Delivery(
          id: 'b',
          service: 'water',
          date: '2026-01-01',
          quantityMilli: 1000,
          ratePaise: 4000,
        ),
      );
      await store.savePayment(
        Payment(
          id: 'p',
          service: 'milk',
          month: '2025-12-01',
          date: '2026-01-02',
          amount: 2000,
        ),
      );
      await store.savePayment(
        Payment(
          id: 'q',
          service: 'milk',
          month: '2025-12-01',
          date: '2026-01-03',
          amount: 5000,
        ),
      );
      expect(store.paid(DateTime(2025, 12), 'milk'), 7000);
      expect(store.paid(DateTime(2026, 1), 'milk'), 0);
      expect(
        store.total(DateTime(2025, 12)) -
            store.paid(DateTime(2025, 12), 'milk'),
        -1000,
      );
      final restored = LedgerStore(await SharedPreferences.getInstance());
      await restored.load();
      expect(restored.total(DateTime(2025, 12)), 6000);
      expect(restored.total(DateTime(2026, 1)), 4000);
      expect(restored.payments.length, 2);
      expect(restored.demo, false);
      await restored.deletePayment('p');
      expect(restored.paid(DateTime(2025, 12), 'milk'), 5000);
    },
  );
}
