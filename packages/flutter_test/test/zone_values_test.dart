import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const Object zoneKey = 'zoneKey';
const String sampleText = 'foo';

void main() async {
  LiveTestWidgetsFlutterBinding();

  testWidgets('can read the zone value', (WidgetTester tester) async {
    await tester.pumpWidget(TestApp());

    expect(find.text(sampleText), findsOneWidget);
  });

}

class TestApp extends StatelessWidget {
  TestApp({super.key});

  @override
  Widget build(BuildContext context) {
    final String? zoneValue = Zone.current[hackZoneKey] as String?;
    return Directionality(
        textDirection: TextDirection.ltr,
        child: Text(zoneValue ?? 'not found'));
  }
}

