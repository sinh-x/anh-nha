import 'package:flutter_test/flutter_test.dart';

import 'package:anh_nha/main.dart';

void main() {
  testWidgets('app boots and renders login route', (WidgetTester tester) async {
    await tester.pumpWidget(const AnhNhaApp());
    await tester.pump();
    expect(find.text('anh-nha — Login'), findsOneWidget);
  });
}