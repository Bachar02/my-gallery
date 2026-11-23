import 'package:ai_gallery/app/app.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/home/presentation/home_screen.dart';
import 'package:ai_gallery/features/onboarding/presentation/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('shows onboarding when access is denied and does not index', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.denied));
    await tester.pumpWidget(env.wrap(const AppGate()));
    await settle(tester);
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(env.indexing.startCalls, 0);
  });

  testWidgets('shows home and starts indexing when access is granted', (tester) async {
    final env = TestEnv();
    await tester.pumpWidget(env.wrap(const AppGate()));
    await settle(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(env.indexing.startCalls, 1);
  });

  testWidgets('limited access goes to home with an explanation', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.limited));
    await tester.pumpWidget(env.wrap(const AppGate()));
    await settle(tester);
    expect(find.byType(LimitedAccessBanner), findsOneWidget);
    expect(env.indexing.startCalls, 1);
  });

  testWidgets('granting access moves from onboarding to home and starts indexing', (tester) async {
    final env = TestEnv(
      gallery: FakeGalleryRepository(permission: GalleryPermission.denied, requestResult: GalleryPermission.granted),
    );
    await tester.pumpWidget(env.wrap(const AppGate()));
    await settle(tester);
    await tapVisible(tester, find.text('Allow photo access'));
    await settle(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(env.indexing.startCalls, 1);
  });

  testWidgets('resume re-checks permission and restarts indexing', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.permanentlyDenied));
    await tester.pumpWidget(env.wrap(const AppGate()));
    await settle(tester);
    expect(find.byType(OnboardingScreen), findsOneWidget);

    env.gallery.permission = GalleryPermission.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(env.indexing.startCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('permission check failure shows retry', (tester) async {
    final env = TestEnv();
    env.gallery.statusError = Exception('boom');
    await tester.pumpWidget(env.wrap(const AppGate()));
    await settle(tester);
    expect(find.text('Couldn’t check photo access'), findsOneWidget);

    env.gallery.statusError = null;
    await tester.tap(find.text('Try again'));
    await settle(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
