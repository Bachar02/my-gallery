import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/gallery/domain/image_kind_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyImageKind', () {
    ImageKind k(String? path, String? name) =>
        classifyImageKind(relativePath: path, filename: name);

    test('OEM screenshot folders', () {
      for (final path in [
        'Pictures/Screenshots/', // AOSP / Pixel / Motorola / OnePlus
        'DCIM/Screenshots/', // Samsung / Xiaomi / Oppo / Realme / Vivo
        'DCIM/Screenshot/',
        'Pictures/Screen captures/',
        'Pictures/ScreenCapture/',
        'Pictures/screen_shots/',
        'Pictures/Captures d\'écran/',
        'Pictures/Bildschirmfotos/',
        '/storage/emulated/0/Pictures/Screenshots', // Android 9 absolute parent
        'Pictures/截屏/',
      ]) {
        expect(k(path, 'IMG_0001.jpg'), ImageKind.screenshot, reason: path);
      }
    });

    test('screenshot filename patterns', () {
      for (final name in [
        'Screenshot_20240101-101010.png',
        'Screenshot_20240101-101010_Chrome.jpg', // Samsung app suffix
        'Screenshot 2024-01-01 at 10.10.10.png',
        'screenshot.png',
        'Screen Shot 2020-05-01 at 9.00.00 AM.png', // macOS import
        'screencap_001.png',
        'Screen_Capture_2023.png',
        '截屏2024-01-01.png',
      ]) {
        expect(k('Download/', name), ImageKind.screenshot, reason: name);
      }
    });

    test('regular photos', () {
      expect(k('DCIM/Camera/', 'IMG_20240101_101010.jpg'), ImageKind.photo);
      expect(k('Pictures/WhatsApp/', 'IMG-20240101-WA0001.jpg'), ImageKind.photo);
      expect(k('Download/', 'my-screen-design.png'), ImageKind.photo);
      expect(k('Pictures/ScreenRecorder/', 'thumb.jpg'), ImageKind.photo);
      expect(k(null, null), ImageKind.photo);
      expect(k('', ''), ImageKind.photo);
    });

    test('folder match is per segment, not substring', () {
      expect(k('Pictures/Screenshots-of-cats-are-not/', 'cat.jpg'), ImageKind.photo);
      expect(k('Pictures/MyScreenshotsBackup/', 'a.jpg'), ImageKind.photo);
    });
  });

  group('normaliseRelativePath', () {
    test('keeps RELATIVE_PATH form', () {
      expect(normaliseRelativePath('Pictures/Screenshots/'), 'Pictures/Screenshots/');
      expect(normaliseRelativePath('DCIM/Camera'), 'DCIM/Camera/');
    });

    test('strips storage prefixes (Android 9 and below)', () {
      expect(normaliseRelativePath('/storage/emulated/0/Pictures/Screenshots'),
          'Pictures/Screenshots/');
      expect(normaliseRelativePath('/storage/1234-ABCD/DCIM/Camera'), 'DCIM/Camera/');
      expect(normaliseRelativePath('/sdcard/Download'), 'Download/');
    });

    test('null / empty', () {
      expect(normaliseRelativePath(null), isNull);
      expect(normaliseRelativePath(''), isNull);
      expect(normaliseRelativePath('/storage/emulated/0/'), isNull);
    });
  });
}
