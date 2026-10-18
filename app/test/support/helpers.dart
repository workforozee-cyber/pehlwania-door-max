import 'dart:io';

import 'package:pehlwania_pos/data/app_database.dart';
import 'package:pehlwania_pos/data/repository.dart';
import 'package:pehlwania_pos/sync/google_auth.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<(Repository, Directory)> openRepo() async {
  sqfliteFfiInit();
  final dir = await Directory.systemTemp.createTemp('pdm_test_');
  final db = await AppDatabase.open(databaseFactoryFfi, '${dir.path}/test.db');
  return (Repository(db), dir);
}

class FakeAuth implements GoogleAuth {
  int issued = 0;
  int cleared = 0;
  String? failWith; // AuthFailure code
  @override
  Future<String> accessToken({required bool interactive}) async {
    if (failWith != null) throw AuthFailure(failWith!, 'fake auth failure $failWith');
    issued++;
    return 'ya29.fake-token-$issued';
  }

  @override
  Future<void> clearToken(String token) async => cleared++;

  @override
  Future<Map<String, String>> signingInfo() async => {'packageName': 'com.pehlwania.doormax', 'sha1': 'AA:BB'};
}

Map<String, dynamic> settingsApp() => {
      'id': 'app', 'shopName': 'Pehlwania Door Max', 'currency': 'Rs', 'taxPct': 0,
      'branches': [
        {'id': 'b1', 'name': 'Main Branch', 'phone': '0302 1819560', 'address': 'Opposite Civil Rest House'}
      ],
      'activeBranchId': 'b1', 'productsV': 3, 'measureUnit': 'ft',
    };

Map<String, dynamic> customer(String id, String name) =>
    {'id': id, 'name': name, 'phone': '03001234567', 'address': 'Sargodha', 'createdAt': 1700000000000};

/// Invoice: 2 × (36in × 84in) per sq ft @500 = 21,000  +  1 × (4ft × 7.5ft) @1200 = 36,000  => 57,000
Map<String, dynamic> invoice(String id, {String no = 'INV-0001', String? customerId, List<Map<String, dynamic>>? payments}) => {
      'id': id, 'type': 'invoice', 'no': no, 'date': '2026-10-18', 'branchId': 'b1',
      'customerId': customerId ?? '', 'customerName': 'Ali Khan', 'customerPhone': '03001234567',
      'discount': 0, 'taxPct': 0, 'orderStatus': 'pending', 'statusLog': [{'status': 'pending', 'date': '2026-10-18'}],
      '_stockApplied': true, 'createdAt': 1760000000000,
      'items': [
        {'id': '$id-i1', 'desc': '2x2 PVC Ceiling', 'width': 36, 'height': 84, 'mu': 'in', 'qty': 2, 'unit': 'sq ft', 'rate': 500, 'basis': 'sqft', 'line': 1},
        {'id': '$id-i2', 'desc': 'Uv almari', 'width': 4, 'height': 7.5, 'mu': 'ft', 'qty': 1, 'unit': 'sq ft', 'rate': 1200, 'basis': 'sqft', 'line': 2},
      ],
      'payments': payments ?? [
        {'id': '$id-p1', 'amount': 5000, 'date': '2026-10-18T10:00:00.000Z', 'method': 'advance'}
      ],
    };

Map<String, dynamic> product(String id, String name, num price) =>
    {'id': id, 'name': name, 'category': 'Doors', 'unit': 'piece', 'price': price, 'stocked': true, 'stock': 5, 'defaultBasis': 'piece', 'createdAt': 1};

Map<String, dynamic> expense(String id, num amount) =>
    {'id': id, 'date': '2026-10-18', 'amount': amount, 'category': 'Suzuki Transport / Fuel', 'branchId': 'b1', 'description': 'delivery', 'createdAt': 2};

Future<void> seedBasics(Repository repo) async {
  await repo.applyBatch([
    StoreOp.put('settings', settingsApp()),
    StoreOp.put('users', {'id': 'u1', 'username': 'admin', 'name': 'Owner', 'pass': 'x', 'role': 'admin', 'perms': {'dashboard': true}, 'active': true}),
    StoreOp.put('counters', {'id': 'invoice', 'n': 1}),
    StoreOp.put('customers', customer('c1', 'Ali Khan')),
    StoreOp.put('products', product('p1', 'Lassani door', 15000)),
  ]);
}
