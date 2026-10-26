import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heart_rate_scan_standalone/main.dart';

void main() {
  testWidgets('PulseHomePage renders initial instructions and UI elements',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Place Finger on Camera & Flash'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Start Measurement'),
      findsOneWidget,
    );
  });
}
