import 'package:flutter_test/flutter_test.dart';
import 'package:safesight_public/main.dart';

// NOTE: In the widget-test sandbox SharedPreferences (and Firebase) fail fast;
// PublicHomeScreen catches this and lands on the login screen, which is what
// this test asserts.
void main() {
  testWidgets('Public app renders login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MakkalAranApp());
    // Let the session check complete and the loading spinner transition to
    // the login screen.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('MakkalAran Public Safety'), findsOneWidget);
  });
}