/// Screenshot detection from MediaStore metadata only (never from pixels).
library;

import '../../../domain/models.dart';

/// Folder names (normalised: lower case, no spaces / `_` / `-`) that OEMs use
/// for screenshots. Matched against every segment of the relative path, e.g.
/// `Pictures/Screenshots/` (AOSP, Pixel, Motorola, OnePlus, Huawei),
/// `DCIM/Screenshots/` (Samsung One UI, Xiaomi MIUI/HyperOS, Oppo/ColorOS,
/// Realme, Vivo), `Pictures/Screen captures/`, `Pictures/ScreenCapture/`.
const _screenshotFolders = <String>{
  'screenshot',
  'screenshots',
  'screencapture',
  'screencaptures',
  'screengrab',
  'screengrabs',
  'capturedecran', // fr: "Captures d'écran"
  'capturesdecran',
  'bildschirmfotos', // de
  'capturasdepantalla', // es
};

/// Filename prefixes (normalised) used for screenshots: `Screenshot_2024…`,
/// `Screenshot 2024-…`, `Screen Shot 2020-…` (macOS imports), `screencap…`.
const _screenshotFilePrefixes = <String>[
  'screenshot',
  'screencapture',
  'screencap',
  'scrnshot',
];

/// Non-Latin markers seen in screenshot filenames / folders on CN, JP and KR
/// firmware (e.g. Huawei EMUI `截屏`, MIUI CN `截图`).
const _screenshotMarkers = <String>['截屏', '截图', '屏幕截图', 'スクリーンショット', '스크린샷'];

String _normalise(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"[\s_\-'’.]+"), '')
    .replaceAll(RegExp('[éèêë]'), 'e')
    .replaceAll(RegExp('[áàâä]'), 'a');

/// Classifies an image as a screenshot when its relative path contains a
/// screenshot folder or its filename starts with a screenshot prefix.
///
/// [relativePath] is MediaStore's `RELATIVE_PATH` (`Pictures/Screenshots/`)
/// or, on Android 9 and below, an absolute parent directory; both work.
ImageKind classifyImageKind({String? relativePath, String? filename}) {
  if (relativePath != null && relativePath.isNotEmpty) {
    for (final segment in relativePath.split(RegExp(r'[/\\]'))) {
      if (segment.isEmpty) continue;
      if (_screenshotFolders.contains(_normalise(segment))) {
        return ImageKind.screenshot;
      }
      if (_screenshotMarkers.any(segment.contains)) return ImageKind.screenshot;
    }
  }
  if (filename != null && filename.isNotEmpty) {
    final name = _normalise(filename);
    if (_screenshotFilePrefixes.any(name.startsWith)) return ImageKind.screenshot;
    if (_screenshotMarkers.any(filename.contains)) return ImageKind.screenshot;
  }
  return ImageKind.photo;
}

/// Normalises photo_manager's relative path to MediaStore `RELATIVE_PATH`
/// form (`Pictures/Screenshots/`).
///
/// On Android 10+ photo_manager already returns `RELATIVE_PATH`. On Android
/// 9 and below it returns the absolute parent directory, e.g.
/// `/storage/emulated/0/Pictures/Screenshots`; the storage-volume prefix is
/// stripped there. Returns null for null/empty input.
String? normaliseRelativePath(String? path) {
  if (path == null) return null;
  var p = path.replaceAll('\\', '/').trim();
  if (p.isEmpty) return null;
  if (p.startsWith('/')) {
    // /storage/emulated/<user>/..., /storage/<UUID>/..., /sdcard/...
    final m = RegExp(r'^/(?:storage/emulated/\d+|storage/[^/]+|sdcard|mnt/sdcard)/?')
        .firstMatch(p);
    if (m != null) p = p.substring(m.end);
  }
  if (p.isEmpty) return null;
  return p.endsWith('/') ? p : '$p/';
}
