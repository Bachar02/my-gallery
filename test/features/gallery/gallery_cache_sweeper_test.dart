import 'dart:io';

import 'package:ai_gallery/features/gallery/data/gallery_cache_sweeper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory cache;

  setUp(() => cache = Directory.systemTemp.createTempSync('gallery_cache_'));
  tearDown(() {
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  File touch(String rel) => File(p.join(cache.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  test('sweep removes photo_manager copies and share folders only', () async {
    final pm1 = touch('pm_12_IMG_1.jpg');
    final pm2 = touch('pm_13_shot.png');
    final export = touch('share_export/IMG_1.jpg');
    final sharePlus = touch('share_plus/IMG_2.HEIC');
    final keepDb = touch('index.sqlite-journal');
    final keepOther = touch('ocr_123.jpg'); // owned by the indexing module
    final keepNested = touch('glide/pm_not_top_level.bin');

    final deleted = await sweepGalleryCaches(cache);

    expect(deleted, 4);
    expect(pm1.existsSync() || pm2.existsSync(), isFalse);
    expect(export.parent.existsSync(), isFalse);
    expect(sharePlus.parent.existsSync(), isFalse);
    expect(keepDb.existsSync(), isTrue);
    expect(keepOther.existsSync(), isTrue);
    expect(keepNested.existsSync(), isTrue);
  });

  test('sweep of a missing directory is a no-op', () async {
    expect(await sweepGalleryCaches(Directory(p.join(cache.path, 'nope'))), 0);
  });

  test('startup sweep runs once and later callers wait for it', () async {
    var runs = 0;
    final sweep = StartupCacheSweep(() async {
      runs++;
      return cache;
    });
    touch('pm_1_a.jpg');
    await Future.wait([sweep.ensure(), sweep.ensure()]);
    touch('pm_2_b.jpg'); // created after start-up: in use, must survive
    await sweep.ensure();
    expect(runs, 1);
    expect(File(p.join(cache.path, 'pm_1_a.jpg')).existsSync(), isFalse);
    expect(File(p.join(cache.path, 'pm_2_b.jpg')).existsSync(), isTrue);
  });

  group('ScopedCopyTracker', () {
    test('keeps the most recent copies and deletes older ones one by one', () async {
      final deleted = <String>[];
      final t = ScopedCopyTracker(
          cacheDirPath: '/data/user/0/app/cache', keep: 2, delete: (path) async => deleted.add(path));
      await t.handedOut('/data/user/0/app/cache/pm_1_a.jpg');
      await t.handedOut('/data/user/0/app/cache/pm_2_b.jpg');
      expect(deleted, isEmpty);
      await t.handedOut('/data/user/0/app/cache/pm_3_c.jpg');
      expect(deleted, ['/data/user/0/app/cache/pm_1_a.jpg']);
      expect(t.length, 2);
    });

    test('re-handing out a copy refreshes it instead of duplicating', () async {
      final deleted = <String>[];
      final t = ScopedCopyTracker(
          cacheDirPath: '/c', keep: 2, delete: (path) async => deleted.add(path));
      await t.handedOut('/c/pm_1_a.jpg');
      await t.handedOut('/c/pm_2_b.jpg');
      await t.handedOut('/c/pm_1_a.jpg');
      await t.handedOut('/c/pm_3_c.jpg');
      expect(deleted, ['/c/pm_2_b.jpg']);
    });

    test('real MediaStore paths (legacy storage, API 30+) are never touched', () async {
      final deleted = <String>[];
      final t = ScopedCopyTracker(
          cacheDirPath: '/data/user/0/app/cache', keep: 0, delete: (path) async => deleted.add(path));
      await t.handedOut('/storage/emulated/0/DCIM/Camera/pm_IMG.jpg');
      expect(t.isCopy('/storage/emulated/0/DCIM/Camera/IMG.jpg'), isFalse);
      expect(deleted.where((d) => d.startsWith('/storage')), isEmpty);
    });

    test('a failing delete does not break later calls', () async {
      final t = ScopedCopyTracker(
          cacheDirPath: '/c', keep: 1, delete: (path) async => throw const FileSystemException('busy'));
      await t.handedOut('/c/pm_1.jpg');
      await t.handedOut('/c/pm_2.jpg');
      expect(t.length, 1);
    });
  });
}
