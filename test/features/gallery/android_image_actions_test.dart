import 'dart:io';
import 'dart:typed_data';

import 'package:ai_gallery/domain/interfaces.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/gallery/data/android_image_actions.dart';
import 'package:ai_gallery/features/gallery/data/gallery_cache_sweeper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

class _FakeShare {
  final List<ShareParams> shared = [];

  Future<ShareResult> share(ShareParams params) async {
    shared.add(params);
    return const ShareResult('ok', ShareResultStatus.success);
  }
}

class _FakeGallery implements GalleryRepository {
  _FakeGallery({this.file});
  final File? file;

  @override
  Future<File?> originalFile(String id) async => file;

  @override
  Future<Uint8List?> displayImage(String id, {int maxSide = 2048}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GalleryImage _image({String? mime = 'image/heic'}) => GalleryImage(
      id: '42',
      filename: 'IMG_1.HEIC',
      mimeType: mime,
      width: 10,
      height: 10,
      createdAt: DateTime(2024),
      modifiedAt: DateTime(2024),
      kind: ImageKind.photo,
    );

final _noSweep = StartupCacheSweep(() async => Directory.systemTemp.createTempSync('noop'));

void main() {
  test('shares the original file with its MIME type and name', () async {
    final share = _FakeShare();
    final actions = AndroidImageActions(
      _FakeGallery(file: File('/storage/emulated/0/DCIM/Camera/IMG_1.HEIC')),
      shareSheet: share.share, startupSweep: _noSweep,
    );
    await actions.share(_image());
    final params = share.shared.single;
    expect(params.files!.single.path, '/storage/emulated/0/DCIM/Camera/IMG_1.HEIC');
    expect(params.files!.single.mimeType, 'image/heic');
    expect(params.fileNameOverrides, ['IMG_1.HEIC']);
  });

  test('infers the MIME type from the extension when MediaStore has none', () async {
    final share = _FakeShare();
    final actions = AndroidImageActions(
      _FakeGallery(file: File('/x/y/shot.png')),
      shareSheet: share.share, startupSweep: _noSweep,
    );
    await actions.share(_image(mime: null));
    expect(share.shared.single.files!.single.mimeType, 'image/png');
  });

  test('throws when the image is gone entirely', () async {
    final share = _FakeShare();
    final actions = AndroidImageActions(_FakeGallery(), shareSheet: share.share, startupSweep: _noSweep);
    await expectLater(actions.share(_image()), throwsStateError);
    expect(share.shared, isEmpty);
  });
}
