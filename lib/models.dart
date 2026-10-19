import 'package:intl/intl.dart';

String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
int amountFor(int quantityMilli, int ratePaise) =>
    (quantityMilli * ratePaise + 500) ~/ 1000;
String quantityText(int milli) =>
    (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');

class Delivery {
  final String id, service, date, note, status;
  final int quantityMilli, ratePaise;
  Delivery({
    required this.id,
    required this.service,
    required this.date,
    required this.quantityMilli,
    required this.ratePaise,
    this.note = '',
    this.status = 'delivered',
  });
  int get amount =>
      status == 'skipped' ? 0 : amountFor(quantityMilli, ratePaise);
  Map<String, dynamic> toJson() => {
    'id': id,
    'service': service,
    'date': date,
    'quantity_milli': quantityMilli,
    'rate_paise': ratePaise,
    'note': note,
    'status': status,
  };
  factory Delivery.fromJson(Map<String, dynamic> j) => Delivery(
    id: j['id'],
    service: j['service'],
    date: j['date'],
    quantityMilli: j['quantity_milli'],
    ratePaise: j['rate_paise'],
    note: j['note'] ?? '',
    status: j['status'],
  );
}

class Payment {
  final String id, service, month, date, note;
  final int amount;
  Payment({
    required this.id,
    required this.service,
    required this.month,
    required this.date,
    required this.amount,
    this.note = '',
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'service': service,
    'billing_month': month,
    'date': date,
    'amount_paise': amount,
    'note': note,
  };
  factory Payment.fromJson(Map<String, dynamic> j) => Payment(
    id: j['id'],
    service: j['service'],
    month: j['billing_month'],
    date: j['date'],
    amount: j['amount_paise'],
    note: j['note'] ?? '',
  );
}

class Preferences {
  String name, currency, milkSupplier, waterSupplier;
  int milkRate, waterRate, milkQuantity, waterQuantity, budget;
  Preferences({
    this.name = 'Our family',
    this.currency = 'INR',
    this.milkSupplier = 'Milk supplier',
    this.waterSupplier = 'Water supplier',
    this.milkRate = 0,
    this.waterRate = 0,
    this.milkQuantity = 1000,
    this.waterQuantity = 1000,
    this.budget = 0,
  });
  Map<String, dynamic> toJson() => {
    'name': name,
    'currency': currency,
    'milk_supplier': milkSupplier,
    'water_supplier': waterSupplier,
    'milk_rate': milkRate,
    'water_rate': waterRate,
    'milk_quantity': milkQuantity,
    'water_quantity': waterQuantity,
    'budget': budget,
  };
  factory Preferences.fromJson(Map<String, dynamic> j) => Preferences(
    name: j['name'],
    currency: j['currency'],
    milkSupplier: j['milk_supplier'],
    waterSupplier: j['water_supplier'],
    milkRate: j['milk_rate'],
    waterRate: j['water_rate'],
    milkQuantity: j['milk_quantity'],
    waterQuantity: j['water_quantity'],
    budget: j['budget'],
  );
  int rate(String s) => s == 'milk' ? milkRate : waterRate;
  int quantity(String s) => s == 'milk' ? milkQuantity : waterQuantity;
  String supplier(String s) => s == 'milk' ? milkSupplier : waterSupplier;
}

/// A real day's recorded deliveries. An empty day is not an assumed skip.
class ServiceDay {
  const ServiceDay({
    required this.service,
    required this.entries,
    required this.paid,
  });
  final String service;
  final List<Delivery> entries;
  final int paid;
  bool get hasEntries => entries.isNotEmpty;
  int get receivedCount => entries.where((e) => e.status == 'delivered').length;
  int get skippedCount => entries.where((e) => e.status == 'skipped').length;
  int get quantityMilli => entries
      .where((e) => e.status == 'delivered')
      .fold(0, (sum, e) => sum + e.quantityMilli);
  int get amount => entries.fold(0, (sum, e) => sum + e.amount);
  String get paymentStatus => !hasEntries
      ? 'No entry'
      : receivedCount == 0
      ? 'Not received'
      : amount == 0
      ? 'No charge'
      : paid >= amount
      ? 'Paid'
      : paid > 0
      ? 'Part paid'
      : 'Unpaid';
}

class LedgerDay {
  const LedgerDay({
    required this.date,
    required this.milk,
    required this.water,
  });
  final DateTime date;
  final ServiceDay milk, water;
  bool get hasEntries => milk.hasEntries || water.hasEntries;
  ServiceDay forService(String service) => service == 'milk' ? milk : water;
}
