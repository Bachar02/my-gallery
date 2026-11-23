import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../domain/interfaces.dart';
import '../../../domain/models.dart';

/// [ImageActions] using the Android share sheet (share_plus).
///
/// Shares the original file with its MIME type. If the original is not
/// readable (cloud-only, revoked, moved) a JPEG rendered by
/// [GalleryRepository.displayImage] is shared instead. Nothing is uploaded
/// by the app itself; the user picks the target in the system sheet.
class AndroidImageActions implements ImageActions {
  AndroidImageActions(
    this._gallery, {
    Future<ShareResult> Function(ShareParams params)? shareSheet,
    this.fallbackMaxSide = 2048,
  }) : _shareSheet = shareSheet ?? SharePlus.instance.share;

  final GalleryRepository _gallery;
  final Future<ShareResult> Function(ShareParams params) _shareSheet;
  final int fallbackMaxSide;

  /// Throws [StateError] when the image no longer exists at all.
  @override
  Future<void> share(GalleryImage image) async {
    final file = await _gallery.originalFile(image.id);
    if (file != null) {
      await _shareSheet(ShareParams(
        files: [XFile(file.path, mimeType: image.mimeType ?? _mimeFromName(file.path))],
        fileNameOverrides: [image.filename ?? p.basename(file.path)],
      ));
      return;
    }

    final jpeg = await _gallery.displayImage(image.id, maxSide: fallbackMaxSide);
    if (jpeg == null) {
      throw StateError('Image ${image.id} is no longer available');
    }
    final export = await _writeExport(image, jpeg);
    await _shareSheet(ShareParams(
      files: [XFile(export.path, mimeType: 'image/jpeg')],
    ));
  }

  /// Writes the fallback JPEG to a private cache folder that is emptied on
  /// every export, so shared copies do not accumulate.
  Future<File> _writeExport(GalleryImage image, Uint8List jpeg) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'share_export'));
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    await dir.create(recursive: true);
    final base = p.basenameWithoutExtension(image.filename ?? 'image_${image.id}');
    final file = File(p.join(dir.path, '${_safe(base)}.jpg'));
    await file.writeAsBytes(jpeg, flush: true);
    return file;
  }

  static String _safe(String name) {
    final s = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return s.isEmpty ? 'image' : s;
  }

  @visibleForTesting
  static String? mimeFromName(String path) => _mimeFromName(path);

  static String? _mimeFromName(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.heic':
        return 'image/heic';
      case '.heif':
        return 'image/heif';
      case '.avif':
        return 'image/avif';
      case '.bmp':
        return 'image/bmp';
      case '.dng':
        return 'image/x-adobe-dng';
      default:
        return null;
    }
  }
}
