import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/gallery/domain/permission_mapping.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart' show PermissionState;

void main() {
  group('mapPermissionState', () {
    test('maps every state', () {
      expect(mapPermissionState(PermissionState.authorized), GalleryPermission.granted);
      expect(mapPermissionState(PermissionState.limited), GalleryPermission.limited);
      expect(mapPermissionState(PermissionState.denied), GalleryPermission.denied);
      expect(mapPermissionState(PermissionState.notDetermined), GalleryPermission.denied);
      expect(mapPermissionState(PermissionState.restricted), GalleryPermission.denied);
    });

    test('remembers a permanent denial for denied states only', () {
      expect(mapPermissionState(PermissionState.denied, knownPermanentlyDenied: true),
          GalleryPermission.permanentlyDenied);
      expect(mapPermissionState(PermissionState.authorized, knownPermanentlyDenied: true),
          GalleryPermission.granted);
      expect(mapPermissionState(PermissionState.limited, knownPermanentlyDenied: true),
          GalleryPermission.limited);
    });
  });

  group('resolveRequestOutcome', () {
    test('denied after a dialog is a normal denial', () {
      expect(resolveRequestOutcome(PermissionState.denied, dialogShown: true),
          GalleryPermission.denied);
    });

    test('denied without any dialog is permanent', () {
      expect(resolveRequestOutcome(PermissionState.denied, dialogShown: false),
          GalleryPermission.permanentlyDenied);
    });

    test('grants are never permanent denials', () {
      expect(resolveRequestOutcome(PermissionState.authorized, dialogShown: false),
          GalleryPermission.granted);
      expect(resolveRequestOutcome(PermissionState.limited, dialogShown: false),
          GalleryPermission.limited);
    });
  });

  group('permissionDialogLikelyShown', () {
    test('focus loss means a dialog was shown', () {
      expect(permissionDialogLikelyShown(appLostFocus: true, elapsed: Duration.zero), isTrue);
    });

    test('instant answer without focus loss means no dialog', () {
      expect(
          permissionDialogLikelyShown(
              appLostFocus: false, elapsed: const Duration(milliseconds: 80)),
          isFalse);
    });

    test('slow answer counts as a dialog', () {
      expect(permissionDialogLikelyShown(appLostFocus: false, elapsed: const Duration(seconds: 2)),
          isTrue);
    });
  });
}
