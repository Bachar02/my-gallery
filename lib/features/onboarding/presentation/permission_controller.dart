import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../domain/models.dart';

extension GalleryPermissionX on GalleryPermission {
  /// True when the app can read at least some images.
  bool get canBrowse => this == GalleryPermission.granted || this == GalleryPermission.limited;
}

/// Current gallery permission. The app shell decides onboarding vs home
/// from this value; screens call the methods to change it.
final galleryPermissionProvider = AsyncNotifierProvider<GalleryPermissionController, GalleryPermission>(
  GalleryPermissionController.new,
  retry: (_, _) => null,
);

class GalleryPermissionController extends AsyncNotifier<GalleryPermission> {
  @override
  Future<GalleryPermission> build() => ref.watch(galleryRepositoryProvider).permissionStatus();

  /// Shows the system dialog. Throws if the platform call fails (the state
  /// is left unchanged so the caller can show a message).
  Future<GalleryPermission> request() async {
    final result = await ref.read(galleryRepositoryProvider).requestPermission();
    if (ref.mounted) state = AsyncData(result);
    return result;
  }

  /// Re-reads the status without a loading flash (e.g. on app resume).
  Future<void> refresh() async {
    try {
      final status = await ref.read(galleryRepositoryProvider).permissionStatus();
      if (ref.mounted) state = AsyncData(status);
    } catch (e, st) {
      if (ref.mounted && !state.hasValue) state = AsyncError(e, st);
    }
  }

  Future<void> openAppSettings() => ref.read(galleryRepositoryProvider).openAppSettings();

  Future<void> manageLimitedSelection() => ref.read(galleryRepositoryProvider).manageLimitedSelection();
}
