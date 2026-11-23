import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Prefix photo_manager uses for originals it copies into the app cache on
/// Android 10 when scoped storage is active (`cache/pm_<id>_<name>`).
const photoManagerCopyPrefix = 'pm_';

/// Cache sub-folders holding copies of shared images.
const shareCacheFolders = <String>['share_export', 'share_plus'];

/// Deletes leftover copies of user images from the app cache:
/// photo_manager originals (`pm_*`), our share exports and share_plus copies.
///
/// Call it only when nothing can be using those files, i.e. at start-up,
/// before the first share or `originalFile` call. Never throws.
Future<int> sweepGalleryCaches(Directory cacheDir) async {
  var deleted = 0;
  try {
    if (!await cacheDir.exists()) return 0;
    await for (final entity in cacheDir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      try {
        if (entity is File && name.startsWith(photoManagerCopyPrefix)) {
          await entity.delete();
          deleted++;
        } else if (entity is Directory && shareCacheFolders.contains(name)) {
          await entity.delete(recursive: true);
          deleted++;
        }
      } catch (_) {
        // In use or already gone: the next sweep retries.
      }
    }
  } catch (e) {
    debugPrint('gallery cache sweep failed: ${e.runtimeType}');
  }
  return deleted;
}

/// Bounds photo_manager's Android 10 original-file copies.
///
/// With `requestLegacyExternalStorage` (set in the manifest) photo_manager
/// returns the real MediaStore path and copies nothing; this tracker is the
/// fallback for when legacy storage is not granted. Each copy handed out is
/// remembered; once more than [keep] exist, the oldest is deleted, one file
/// at a time (never photo_manager's global `clearFileCache`, which could
/// delete a file a concurrent caller is still reading). Consumers use a file
/// briefly (OCR, share_plus copies it before sharing), so the last [keep]
/// copies cover every in-flight use.
class ScopedCopyTracker {
  ScopedCopyTracker({
    required this.cacheDirPath,
    this.keep = 8,
    Future<void> Function(String path)? delete,
  }) : _delete = delete ?? _deleteFile;

  final String cacheDirPath;
  final int keep;
  final Future<void> Function(String path) _delete;
  final Queue<String> _copies = Queue<String>();

  /// Number of copies currently tracked.
  int get length => _copies.length;

  /// Whether [path] is a photo_manager copy inside the app cache.
  bool isCopy(String path) =>
      p.isWithin(cacheDirPath, path) && p.basename(path).startsWith(photoManagerCopyPrefix);

  /// Records [path] if it is a copy, deleting the oldest copies beyond [keep].
  Future<void> handedOut(String path) async {
    if (!isCopy(path)) return;
    _copies.remove(path); // photo_manager reuses an existing copy
    _copies.addLast(path);
    while (_copies.length > keep) {
      final old = _copies.removeFirst();
      try {
        await _delete(old);
      } catch (_) {}
    }
  }

  static Future<void> _deleteFile(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}

/// Runs [sweepGalleryCaches] once per process. Every code path that hands
/// out a cached copy awaits [ensure] first, so the sweep can never delete a
/// file that is in use.
class StartupCacheSweep {
  StartupCacheSweep(this._cacheDir);

  final Future<Directory> Function() _cacheDir;
  Future<void>? _done;

  Future<void> ensure() => _done ??= () async {
        try {
          await sweepGalleryCaches(await _cacheDir());
        } catch (_) {}
      }();
}

/// The app-wide instance (the app cache directory is `getTemporaryDirectory()`
/// on Android, i.e. `Context.getCacheDir()`).
final StartupCacheSweep galleryStartupSweep = StartupCacheSweep(getTemporaryDirectory);
