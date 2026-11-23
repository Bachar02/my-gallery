// On-device checks of PhotoManagerGalleryRepository.
//
// Preconditions (see the gallery module notes):
//   * test images pushed to /sdcard/Pictures/AIGalleryTest/, Pictures/Screenshots/,
//     DCIM/Screenshots/ and Download/ and a media scan run;
//   * READ_MEDIA_IMAGES (API 33+) or READ_EXTERNAL_STORAGE (API <= 32) granted
//     with `adb shell pm grant com.bachar02.ai_gallery <permission>`.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/gallery/data/photo_manager_gallery_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photo_manager/photo_manager.dart';

Future<ui.Size> _decodeSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = ui.Size(frame.image.width.toDouble(), frame.image.height.toDouble());
  frame.image.dispose();
  codec.dispose();
  return size;
}

bool _isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final repo = PhotoManagerGalleryRepository();
  final byName = <String, GalleryImage>{};
  var all = <GalleryImage>[];

  GalleryImage named(String name) {
    final img = byName[name];
    expect(img, isNotNull, reason: '$name not found in the listing (were test images pushed?)');
    return img!;
  }

  testWidgets('permission is granted', (tester) async {
    // `flutter test` installs a fresh APK, so the permission is granted from
    // the host (adb shell pm grant ...) right after install; wait for it.
    var status = await repo.permissionStatus();
    for (var i = 0; i < 120 && status != GalleryPermission.granted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      status = await repo.permissionStatus();
    }
    print('GALLERY permission=$status');
    expect(status, GalleryPermission.granted);
    // Already granted: returns immediately without UI and must not be
    // mistaken for a permanent denial.
    expect(await repo.requestPermission(), GalleryPermission.granted);
  });

  testWidgets('count and paged listing (newest first, no duplicates)', (tester) async {
    final count = await repo.countImages();
    print('GALLERY count=$count');
    expect(count, greaterThanOrEqualTo(6));

    final sw = Stopwatch()..start();
    var pages = 0;
    await for (final page in repo.listAllImages(pageSize: 200)) {
      pages++;
      all.addAll(page);
    }
    sw.stop();
    print('GALLERY listed=${all.length} pages=$pages in ${sw.elapsedMilliseconds} ms '
        '(${(all.length / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(0)} images/s)');

    expect(all.length, count);
    expect(all.map((e) => e.id).toSet().length, all.length, reason: 'duplicate ids');
    // Order is MediaStore's (DATE_TAKEN, else DATE_ADDED). createdAt may be
    // earlier when recovered from the filename, so it is not checked here.

    // Small pages must yield exactly the same sequence.
    final small = <GalleryImage>[];
    await for (final page in repo.listAllImages(pageSize: 7)) {
      expect(page.length, lessThanOrEqualTo(7));
      small.addAll(page);
    }
    expect(small.map((e) => e.id).toList(), all.map((e) => e.id).toList());

    for (final img in all) {
      if (img.filename != null) byName[img.filename!] = img;
    }
  });

  testWidgets('metadata and screenshot detection', (tester) async {
    final shot = named('Screenshot_20241101-101010.png');
    expect(shot.kind, ImageKind.screenshot);
    expect(shot.relativePath, 'Pictures/Screenshots/');
    expect(shot.mimeType, 'image/png');
    expect((shot.width, shot.height), (1080, 2400));
    // Pushed with adb (no DATE_TAKEN): capture date recovered from the name.
    expect(shot.createdAt, DateTime(2024, 11, 1, 10, 10, 10));

    final samsung = named('Screenshot_20241102-111111_Chrome.jpg');
    expect(samsung.kind, ImageKind.screenshot);
    expect(samsung.relativePath, 'DCIM/Screenshots/');

    final download = named('Screenshot_20240505-090000.png');
    expect(download.kind, ImageKind.screenshot, reason: 'filename pattern outside a screenshot folder');
    expect(download.relativePath, 'Download/');

    final photo = named('IMG_landscape.jpg');
    expect(photo.kind, ImageKind.photo);
    expect(photo.relativePath, 'Pictures/AIGalleryTest/');
    expect(photo.mimeType, 'image/jpeg');
    expect((photo.width, photo.height), (1600, 1200));
    expect(photo.createdAt.year, greaterThanOrEqualTo(2024));
    expect(photo.modifiedAt.millisecondsSinceEpoch, greaterThan(0));

    final counts = <ImageKind, int>{};
    for (final i in all) {
      counts[i.kind] = (counts[i.kind] ?? 0) + 1;
    }
    print('GALLERY kinds=$counts');

    final fetched = await repo.getImage(photo.id);
    expect(fetched, isNotNull);
    expect(fetched!.id, photo.id);
    expect(fetched.filename, 'IMG_landscape.jpg');
    expect(fetched.kind, ImageKind.photo);
    expect((fetched.width, fetched.height), (1600, 1200));
  });

  testWidgets('thumbnails: JPEG, longest side = size, cached', (tester) async {
    final photo = named('IMG_landscape.jpg');
    final shot = named('Screenshot_20241101-101010.png');

    final sw = Stopwatch()..start();
    final t1 = await repo.thumbnail(photo.id, size: 256);
    final firstMs = sw.elapsedMilliseconds;
    expect(t1, isNotNull);
    expect(t1!.isNotEmpty, isTrue);
    expect(_isJpeg(t1), isTrue);
    expect(await _decodeSize(t1), const ui.Size(256, 192));

    sw.reset();
    final t2 = await repo.thumbnail(photo.id, size: 256);
    final cachedUs = sw.elapsedMicroseconds;
    expect(identical(t1, t2), isTrue, reason: 'second call should hit the LRU cache');
    print('GALLERY thumbnail first=${firstMs}ms cached=${cachedUs}us bytes=${t1.length}');

    final ts = await repo.thumbnail(shot.id, size: 256);
    expect(ts, isNotNull);
    expect(_isJpeg(ts!), isTrue, reason: 'PNG source is re-encoded as JPEG');
    expect(await _decodeSize(ts), const ui.Size(115, 256));

    // Grid-style burst: 60 thumbnails concurrently.
    sw.reset();
    final burst = await Future.wait(all.take(60).map((i) => repo.thumbnail(i.id, size: 192)));
    print('GALLERY 60 thumbnails (192px) in ${sw.elapsedMilliseconds} ms, '
        'nulls=${burst.where((b) => b == null).length}');
    expect(burst.where((b) => b == null || b.isEmpty), isEmpty);
  });

  testWidgets('displayImage: JPEG within maxSide, never upscaled', (tester) async {
    final photo = named('IMG_landscape.jpg');
    final d = await repo.displayImage(photo.id, maxSide: 1024);
    expect(d, isNotNull);
    expect(_isJpeg(d!), isTrue);
    expect(await _decodeSize(d), const ui.Size(1024, 768));

    final webp = named('IMG_small.webp');
    final w = await repo.displayImage(webp.id, maxSide: 2048);
    expect(w, isNotNull);
    expect(_isJpeg(w!), isTrue, reason: 'WebP decoded and re-encoded as JPEG');
    expect(await _decodeSize(w), const ui.Size(300, 200));
  });

  testWidgets('originalFile exists', (tester) async {
    final photo = named('IMG_landscape.jpg');
    final f = await repo.originalFile(photo.id);
    expect(f, isNotNull);
    expect(await f!.exists(), isTrue);
    expect(await f.length(), greaterThan(0));
    expect(f.path, endsWith('IMG_landscape.jpg'));
    print('GALLERY originalFile=${f.path}');
  });

  testWidgets('missing ids return null, never throw', (tester) async {
    const missing = '987654321';
    expect(await repo.getImage(missing), isNull);
    expect(await repo.thumbnail(missing), isNull);
    expect(await repo.displayImage(missing), isNull);
    expect(await repo.originalFile(missing), isNull);
    expect(await repo.getImage('not-a-number'), isNull);
  });

  testWidgets('changes stream emits (debounced) when MediaStore changes', (tester) async {
    var events = 0;
    final first = Completer<void>();
    final sub = repo.changes.listen((_) {
      events++;
      if (!first.isCompleted) first.complete();
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final png = (await repo.thumbnail(named('IMG_small.webp').id, size: 64))!;
    final saved = await PhotoManager.editor.saveImage(
      png,
      filename: 'ai_gallery_change_probe.jpg',
      relativePath: 'Pictures/AIGalleryTest',
    );
    print('GALLERY probe saved id=${saved.id}');

    await first.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(seconds: 2));
    print('GALLERY change events=$events');
    expect(events, greaterThanOrEqualTo(1));
    expect(events, lessThanOrEqualTo(2), reason: 'a single insert should be debounced');

    final probe = await repo.getImage(saved.id);
    expect(probe, isNotNull);
    expect(probe!.relativePath, 'Pictures/AIGalleryTest/');
    await sub.cancel();
  });
}
