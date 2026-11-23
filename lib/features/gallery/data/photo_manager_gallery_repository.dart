import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../domain/interfaces.dart';
import '../../../domain/models.dart';
import '../domain/capture_date.dart';
import '../domain/image_kind_classifier.dart';
import '../domain/permission_mapping.dart';
import '../domain/thumbnail_geometry.dart';
import 'byte_lru_cache.dart';
import 'gallery_cache_sweeper.dart';

/// [GalleryRepository] backed by Android MediaStore through photo_manager.
///
/// * Images only (no video/audio), newest first by MediaStore date
///   (DATE_TAKEN, else DATE_ADDED). `createdAt` can be earlier than that
///   order suggests when it is recovered from the filename.
/// * Every call goes through platform channels, so use it from the root
///   isolate. Decoding/encoding happens natively (Glide) off the UI thread.
/// * Never throws for revoked permission or deleted files: returns
///   null / empty instead.
class PhotoManagerGalleryRepository implements GalleryRepository {
  PhotoManagerGalleryRepository({
    int thumbnailCacheBytes = 30 * 1024 * 1024,
    this.changeDebounce = const Duration(milliseconds: 500),
    int maxConcurrentDecodes = 6,
    StartupCacheSweep? startupSweep,
  })  : _thumbs = ByteLruCache<String>(maxBytes: thumbnailCacheBytes),
        _decodePool = _Pool(maxConcurrentDecodes),
        _startupSweep = startupSweep ?? galleryStartupSweep {
    // The repository is created at app start (indexing): clear copies of
    // user images left in the cache by an earlier process (QA-08/QA-09).
    unawaited(_startupSweep.ensure());
  }

  final StartupCacheSweep _startupSweep;
  ScopedCopyTracker? _copies;

  /// Quiet period after the last MediaStore notification before [changes]
  /// emits (a burst of new screenshots / a camera save produces many).
  final Duration changeDebounce;

  static const _permissionOption = PermissionRequestOption(
    androidPermission: AndroidPermission(type: RequestType.image, mediaLocation: false),
  );
  static const _thumbnailQuality = 85;
  static const _displayQuality = 90;
  static const _maxMetaEntries = 50000;

  final ByteLruCache<String> _thumbs;
  final _Pool _decodePool;

  /// id -> dimensions/modification time learned from listings, so
  /// thumbnail() does not need a MediaStore lookup per call.
  final LinkedHashMap<String, _Meta> _meta = LinkedHashMap<String, _Meta>();

  bool _knownPermanentlyDenied = false;

  /// MediaStore sort order. `datetaken` (ms) is the capture date; fall back
  /// to `date_added` (s) where it is missing (many screenshots, downloads).
  /// If a device's MediaProvider rejects the expression, plain `date_added`
  /// ordering is used instead.
  bool _orderByDateTaken = true;

  // ------------------------------------------------------------ permissions

  @override
  Future<GalleryPermission> permissionStatus() async {
    try {
      final state = await PhotoManager.getPermissionState(requestOption: _permissionOption);
      final result = mapPermissionState(state, knownPermanentlyDenied: _knownPermanentlyDenied);
      if (result == GalleryPermission.granted || result == GalleryPermission.limited) {
        _knownPermanentlyDenied = false;
      }
      return result;
    } catch (e) {
      debugPrint('GalleryRepository.permissionStatus failed: $e');
      return GalleryPermission.denied;
    }
  }

  @override
  Future<GalleryPermission> requestPermission() async {
    var lostFocus = false;
    AppLifecycleListener? listener;
    try {
      listener = AppLifecycleListener(onStateChange: (s) {
        if (s != AppLifecycleState.resumed) lostFocus = true;
      });
    } catch (_) {
      // No WidgetsBinding (e.g. headless use): rely on timing only.
    }
    final stopwatch = Stopwatch()..start();
    PermissionState state;
    try {
      state = await PhotoManager.requestPermissionExtend(requestOption: _permissionOption);
    } catch (e) {
      debugPrint('GalleryRepository.requestPermission failed: $e');
      return GalleryPermission.denied;
    } finally {
      stopwatch.stop();
      listener?.dispose();
    }
    final result = resolveRequestOutcome(
      state,
      dialogShown: permissionDialogLikelyShown(appLostFocus: lostFocus, elapsed: stopwatch.elapsed),
    );
    _knownPermanentlyDenied = result == GalleryPermission.permanentlyDenied;
    if (result == GalleryPermission.granted || result == GalleryPermission.limited) {
      _invalidate();
    }
    return result;
  }

  @override
  Future<void> openAppSettings() async {
    try {
      await PhotoManager.openSetting();
    } catch (e) {
      debugPrint('GalleryRepository.openAppSettings failed: $e');
    }
  }

  @override
  Future<void> manageLimitedSelection() async {
    try {
      await PhotoManager.presentLimited(type: RequestType.image);
    } catch (e) {
      // Not available below Android 14.
      debugPrint('GalleryRepository.manageLimitedSelection failed: $e');
      return;
    }
    // The accessible set may have changed; tell listeners right away.
    _invalidate();
    if (_changes.hasListener) _changes.add(null);
  }

  // ---------------------------------------------------------------- listing

  PMFilter _filter() {
    const c = CustomColumns.android;
    return CustomFilter.sql(
      where: '${c.mediaType} = 1',
      orderBy: [
        if (_orderByDateTaken)
          OrderByItem.desc('COALESCE(${c.dateTaken}, ${c.createDate} * 1000)')
        else
          OrderByItem.desc(c.createDate),
        OrderByItem.desc(c.id),
      ],
    );
  }

  Future<List<AssetEntity>> _range(int start, int end) async {
    try {
      return await PhotoManager.getAssetListRange(
          start: start, end: end, filterOption: _filter(), type: RequestType.image);
    } catch (e) {
      if (!_orderByDateTaken) rethrow;
      debugPrint('GalleryRepository: date-taken ordering rejected ($e); using date_added');
      _orderByDateTaken = false;
      return PhotoManager.getAssetListRange(
          start: start, end: end, filterOption: _filter(), type: RequestType.image);
    }
  }

  @override
  Stream<List<GalleryImage>> listAllImages({int pageSize = 200}) async* {
    assert(pageSize > 0, 'pageSize must be positive');
    final total = await countImages();
    if (total == 0) return;
    // Offsets can shift if images are added while paging; ids already
    // delivered are skipped so a page never repeats an image. Callers should
    // re-sync when [changes] fires.
    final seen = HashSet<String>();
    for (var start = 0; start < total; start += pageSize) {
      List<AssetEntity> page;
      try {
        page = await _range(start, start + pageSize);
      } catch (e) {
        debugPrint('GalleryRepository.listAllImages stopped at $start: $e');
        return;
      }
      // photo_manager silently drops rows whose file no longer exists, so a
      // short (or empty) page does not mean the end; [total] bounds the loop.
      final images = <GalleryImage>[
        for (final e in page)
          if (e.type == AssetType.image && seen.add(e.id)) _toImage(e),
      ];
      if (images.isNotEmpty) yield images;
    }
  }

  @override
  Future<int> countImages() async {
    try {
      return await PhotoManager.getAssetCount(filterOption: _filter(), type: RequestType.image);
    } catch (e) {
      debugPrint('GalleryRepository.countImages failed: $e');
      return 0;
    }
  }

  @override
  Future<GalleryImage?> getImage(String id) async {
    final entity = await _entity(id);
    return entity == null ? null : _toImage(entity);
  }

  Future<AssetEntity?> _entity(String id) async {
    try {
      final e = await AssetEntity.fromId(id);
      if (e == null || e.type != AssetType.image) return null;
      return e;
    } catch (_) {
      return null;
    }
  }

  GalleryImage _toImage(AssetEntity e) {
    final rel = normaliseRelativePath(e.relativePath);
    final title = (e.title == null || e.title!.isEmpty) ? null : e.title;
    // DATE_TAKEN, else DATE_ADDED (photo_manager), else DATE_MODIFIED; then a
    // filename date wins when MediaStore's value is clearly a copy time.
    final mediaStoreCreated =
        (e.createDateSecond ?? 0) > 0 ? e.createDateTime : e.modifiedDateTime;
    final created = chooseCreatedAt(
      mediaStoreCreated: mediaStoreCreated,
      filenameDate: parseFilenameDate(title),
    );
    final width = e.orientatedWidth;
    final height = e.orientatedHeight;
    _remember(e.id, _Meta(width, height, e.modifiedDateSecond ?? 0));
    return GalleryImage(
      id: e.id,
      filename: title,
      relativePath: rel,
      mimeType: (e.mimeType == null || e.mimeType!.isEmpty) ? null : e.mimeType,
      width: width,
      height: height,
      createdAt: created,
      modifiedAt: e.modifiedDateTime,
      kind: classifyImageKind(relativePath: rel, filename: title),
    );
  }

  void _remember(String id, _Meta meta) {
    _meta.remove(id);
    _meta[id] = meta;
    if (_meta.length > _maxMetaEntries) _meta.remove(_meta.keys.first);
  }

  Future<_Meta?> _metaFor(String id) async {
    final known = _meta[id];
    if (known != null) return known;
    final e = await _entity(id);
    if (e == null) return null;
    _toImage(e); // records meta
    return _meta[id];
  }

  // ----------------------------------------------------------------- images

  @override
  Future<Uint8List?> thumbnail(String id, {int size = 256}) async {
    if (size <= 0) return null;
    final meta = await _metaFor(id);
    if (meta == null) return null;
    final key = '$id:${meta.modifiedSec}:$size';
    try {
      return await _thumbs.getOrLoad(
          key, () => _decode(id, meta, size, _thumbnailQuality));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> displayImage(String id, {int maxSide = 2048}) async {
    if (maxSide <= 0) return null;
    final meta = await _metaFor(id);
    if (meta == null) return null;
    return _decode(id, meta, maxSide, _displayQuality);
  }

  /// Asks the platform (Glide on Android, using MediaStore / the system
  /// decoders, so HEIC/WebP/etc. work) for a JPEG of the right size.
  Future<Uint8List?> _decode(String id, _Meta meta, int longestSide, int quality) {
    final target = fitWithin(meta.width, meta.height, longestSide);
    return _decodePool.run(() async {
      try {
        final entity = AssetEntity(
          id: id,
          typeInt: AssetType.image.index,
          width: meta.width,
          height: meta.height,
        );
        final bytes = await entity.thumbnailDataWithSize(
          ThumbnailSize(target.width, target.height),
          format: ThumbnailFormat.jpeg,
          quality: quality,
        );
        return (bytes == null || bytes.isEmpty) ? null : bytes;
      } catch (e) {
        // Deleted, revoked or undecodable.
        return null;
      }
    });
  }

  @override
  Future<File?> originalFile(String id) async {
    try {
      final entity = await _entity(id);
      if (entity == null) return null;
      await _startupSweep.ensure();
      final file = await entity.file;
      if (file == null || !await file.exists()) return null;
      // Android 10 without legacy storage: photo_manager copies the original
      // into cache/pm_*. Keep only the most recent copies.
      _copies ??= ScopedCopyTracker(cacheDirPath: (await getTemporaryDirectory()).path);
      await _copies!.handedOut(file.path);
      return file;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- changes

  late final StreamController<void> _changes = StreamController<void>.broadcast(
    onListen: _startNotify,
    onCancel: _stopNotify,
  );
  Timer? _debounce;

  @override
  Stream<void> get changes => _changes.stream;

  void _onPlatformChange(MethodCall call) {
    _debounce?.cancel();
    _debounce = Timer(changeDebounce, () {
      _invalidate();
      if (_changes.hasListener) _changes.add(null);
    });
  }

  Future<void> _startNotify() async {
    try {
      PhotoManager.addChangeCallback(_onPlatformChange);
      await PhotoManager.startChangeNotify();
    } catch (e) {
      debugPrint('GalleryRepository: change notifications unavailable: $e');
    }
  }

  Future<void> _stopNotify() async {
    _debounce?.cancel();
    try {
      PhotoManager.removeChangeCallback(_onPlatformChange);
      await PhotoManager.stopChangeNotify();
    } catch (_) {}
  }

  /// Drops cached metadata (thumbnail keys include the modification time,
  /// so stale thumbnails are never served once metadata is refreshed).
  void _invalidate() => _meta.clear();

  /// Releases cached thumbnails (e.g. on memory pressure).
  void clearCache() {
    _thumbs.clear();
    _meta.clear();
  }
}

class _Meta {
  const _Meta(this.width, this.height, this.modifiedSec);
  final int width;
  final int height;
  final int modifiedSec;
}

/// Limits concurrent native decodes so a fast-scrolling grid cannot queue
/// hundreds of full decodes ahead of the image the user is looking at.
class _Pool {
  _Pool(this.max);
  final int max;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= max) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    } else {
      _active++;
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}
