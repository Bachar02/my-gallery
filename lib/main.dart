import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'core/design/app_theme.dart';
import 'core/widgets/state_views.dart';
import 'data/db/sqlite_index_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final SqliteIndexStore store;
  try {
    // Recreates the file itself if it is corrupted; only fails if app-private
    // storage is unusable (e.g. the device is out of space).
    store = await SqliteIndexStore.openDefault();
  } catch (e) {
    debugPrint('Could not open the local index: $e');
    runApp(const _StartupFailureApp());
    return;
  }

  runApp(ProviderScope(
    overrides: [indexStoreProvider.overrideWithValue(store)],
    child: const AiGalleryApp(),
  ));
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const Scaffold(
          body: SafeArea(
            child: ErrorView(
              title: 'AI Gallery could not start',
              message: 'Your phone may be low on storage. Free up some space, then reopen the app.',
            ),
          ),
        ),
      );
}
