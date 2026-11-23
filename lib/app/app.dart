import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design/app_theme.dart';
import '../core/design/tokens.dart';
import '../core/widgets/state_views.dart';
import '../domain/models.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/home/presentation/indexing_controller.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/onboarding/presentation/permission_controller.dart';
import 'providers.dart';

class AiGalleryApp extends StatelessWidget {
  const AiGalleryApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AI Gallery',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        home: const AppGate(),
      );
}

/// Root screen. Shows onboarding until the app can read photos, then Home.
///
/// Also owns app-level orchestration: starts indexing once access is
/// available and again whenever the app returns to the foreground, and
/// refreshes index stats when an indexing run changes phase.
class AppGate extends ConsumerStatefulWidget {
  const AppGate({super.key});

  @override
  ConsumerState<AppGate> createState() => _AppGateState();
}

class _AppGateState extends ConsumerState<AppGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual<AsyncValue<GalleryPermission>>(galleryPermissionProvider, (previous, next) {
      final was = previous?.value?.canBrowse ?? false;
      final now = next.value?.canBrowse ?? false;
      if (now && !was) _startIndexing();
    }, fireImmediately: true);
    ref.listenManual<AsyncValue<IndexingProgress>>(indexingProgressProvider, (previous, next) {
      final before = previous?.value?.phase;
      final after = next.value?.phase;
      if (after != null && after != before && !(next.value?.isRunning ?? true)) {
        ref.invalidate(indexStatsProvider);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_onResume());
  }

  Future<void> _onResume() async {
    await ref.read(galleryPermissionProvider.notifier).refresh();
    if (!mounted) return;
    if (ref.read(galleryPermissionProvider).value?.canBrowse ?? false) _startIndexing();
  }

  void _startIndexing() => unawaited(ref.read(indexingActionsProvider).start());

  @override
  Widget build(BuildContext context) {
    final permission = ref.watch(galleryPermissionProvider);
    final Widget child;
    if (permission.value case final p?) {
      child = p.canBrowse ? const HomeScreen(key: ValueKey('home')) : OnboardingScreen(key: const ValueKey('onboarding'), permission: p);
    } else if (permission.hasError) {
      child = Scaffold(
        key: const ValueKey('error'),
        body: SafeArea(
          child: ErrorView(
            title: 'Couldn’t check photo access',
            onRetry: () => ref.invalidate(galleryPermissionProvider),
          ),
        ),
      );
    } else {
      child = const Scaffold(
        key: ValueKey('loading'),
        body: Center(child: CircularProgressIndicator(semanticsLabel: 'Loading')),
      );
    }
    return AnimatedSwitcher(duration: AppMotion.medium, child: child);
  }
}
