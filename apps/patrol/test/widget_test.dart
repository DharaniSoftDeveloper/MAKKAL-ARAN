import 'package:flutter_test/flutter_test.dart';
import 'package:safesight_patrol/main.dart';

// NOTE: The app's session restore (Supabase/Firebase) intentionally fails fast
// inside the widget-test sandbox; PatrolHome catches those errors and lands on
// the login screen, which is what this test asserts.
void main() {
  testWidgets('Patrol app renders login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const PatrolApp());
    // Let the (failing-fast) session restore complete and the loading spinner
    // transition to the login screen.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('MakkalAran Patrol'), findsOneWidget);
    expect(find.text('Sign In to Duty'), findsOneWidget);
  });
}