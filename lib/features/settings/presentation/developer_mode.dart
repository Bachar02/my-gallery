import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';

/// Hidden developer option: shows how every search result was scored
/// (Settings > About: tap the version 7 times). Off by default; the value is
/// a local store setting and nothing leaves the device.
const developerModeSettingKey = 'dev.scoreBreakdown';

/// Taps on the version row needed to toggle developer mode.
const developerModeTaps = 7;

final developerModeProvider = AsyncNotifierProvider<DeveloperModeController, bool>(DeveloperModeController.new);

class DeveloperModeController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    try {
      return await ref.read(indexStoreProvider).getSetting(developerModeSettingKey) == '1';
    } catch (_) {
      return false;
    }
  }

  /// Flips the option and returns the new value.
  Future<bool> toggle() async {
    final next = !(state.value ?? false);
    await ref.read(indexStoreProvider).setSetting(developerModeSettingKey, next ? '1' : null);
    state = AsyncData(next);
    return next;
  }
}
