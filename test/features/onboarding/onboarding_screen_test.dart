import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/onboarding/presentation/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/fakes.dart';

void main() {
  testWidgets('explains privacy and requests access', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.denied));
    await tester.pumpWidget(env.wrap(const OnboardingScreen(permission: GalleryPermission.denied)));
    await tester.pump();

    expect(find.text('Find any photo by describing it'), findsOneWidget);
    expect(find.textContaining('no internet permission'), findsOneWidget);
    expect(find.textContaining('doesn’t recognise faces'), findsOneWidget);

    await tapVisible(tester, find.text('Allow photo access'));
    await tester.pump();
    await tester.pump();
    expect(env.gallery.requestCalls, 1);
    // Still denied: the screen explains and offers to try again.
    expect(find.textContaining('wasn’t allowed'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('permanently denied opens app settings', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.permanentlyDenied));
    await tester.pumpWidget(env.wrap(const OnboardingScreen(permission: GalleryPermission.permanentlyDenied)));
    await tester.pump();

    expect(find.textContaining('turned off'), findsOneWidget);
    expect(find.text('Allow photo access'), findsNothing);
    await tapVisible(tester, find.text('Open Settings'));
    await tester.pump();
    expect(env.gallery.openSettingsCalls, 1);
  });

  testWidgets('request failure shows a message', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.denied));
    env.gallery.requestError = Exception('platform');
    await tester.pumpWidget(env.wrap(const OnboardingScreen(permission: GalleryPermission.denied)));
    await tapVisible(tester, find.text('Allow photo access'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Couldn’t show the permission dialog'), findsOneWidget);
  });

  testWidgets('fits at 200% text size on a small phone', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.denied));
    await tester.pumpWidget(env.wrap(const OnboardingScreen(permission: GalleryPermission.permanentlyDenied), textScale: 2));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
