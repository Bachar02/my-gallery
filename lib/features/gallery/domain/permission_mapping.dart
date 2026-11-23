/// Pure mapping between photo_manager permission states and the app's
/// [GalleryPermission].
library;

import 'package:photo_manager/photo_manager.dart' show PermissionState;

import '../../../domain/models.dart';

/// Maps a plain status query (no request made).
///
/// Android cannot tell "never asked" from "permanently denied" without a
/// request, so [knownPermanentlyDenied] carries what an earlier
/// [resolveRequestOutcome] learned in this process.
GalleryPermission mapPermissionState(
  PermissionState state, {
  bool knownPermanentlyDenied = false,
}) {
  switch (state) {
    case PermissionState.authorized:
      return GalleryPermission.granted;
    case PermissionState.limited:
      return GalleryPermission.limited;
    case PermissionState.notDetermined:
    case PermissionState.denied:
    case PermissionState.restricted:
      return knownPermanentlyDenied
          ? GalleryPermission.permanentlyDenied
          : GalleryPermission.denied;
  }
}

/// Maps the result of a permission *request*.
///
/// Heuristic for "permanently denied": Android answers a request instantly,
/// without showing any dialog, once the user has denied twice (Android 11+)
/// or ticked "Don't ask again" (Android 8–10). So a request that comes back
/// denied while no system dialog was shown is permanently denied.
/// [dialogShown] is true when the app lost focus during the request (the
/// permission dialog covers the activity) or the request took long enough
/// that a human must have answered it.
GalleryPermission resolveRequestOutcome(
  PermissionState state, {
  required bool dialogShown,
}) {
  final mapped = mapPermissionState(state);
  if (mapped == GalleryPermission.denied && !dialogShown) {
    return GalleryPermission.permanentlyDenied;
  }
  return mapped;
}

/// Requests that return faster than this cannot have involved a human
/// answering a dialog. Used together with app-lifecycle focus tracking.
const permissionDialogMinDuration = Duration(milliseconds: 700);

/// Whether a permission request most likely displayed a system dialog.
bool permissionDialogLikelyShown({
  required bool appLostFocus,
  required Duration elapsed,
}) =>
    appLostFocus || elapsed >= permissionDialogMinDuration;
