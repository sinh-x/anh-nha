import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:anh_nha/main.dart';

void main() {
  // sqflite is not available in the Flutter test environment on the host
  // (no Android runtime). Use the FFI binding + in-memory factory so the
  // bootstrap path that opens SyncQueueDb does not throw "databaseFactory
  // not initialized".
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('app boots and renders login route', (WidgetTester tester) async {
    await tester.pumpWidget(const AnhNhaApp());
    await tester.pump();
    expect(find.text('anh-nha — Login'), findsOneWidget);
  });
}