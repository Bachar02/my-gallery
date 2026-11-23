import 'package:ai_gallery/features/gallery/domain/capture_date.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseFilenameDate', () {
    final cases = <String, DateTime>{
      'IMG_20260718_201500.jpg': DateTime(2026, 7, 18, 20, 15, 0),
      'IMG-20260718-WA0001.jpg': DateTime(2026, 7, 18, 12),
      'Screenshot_20261020-090210.png': DateTime(2026, 10, 20, 9, 2, 10),
      'Screenshot_2026-10-20-09-02-10-123_com.app.png': DateTime(2026, 10, 20, 9, 2, 10),
      'PXL_20260718_201500123.jpg': DateTime(2026, 7, 18, 20, 15, 0),
      'VID_20260718.mp4': DateTime(2026, 7, 18, 12),
      'IMG_20260718.jpg': DateTime(2026, 7, 18, 12),
      'signal-2026-07-18-201500.jpg': DateTime(2026, 7, 18, 20, 15, 0),
      '2026-07-18 20.15.00.jpg': DateTime(2026, 7, 18, 20, 15, 0),
      'Screenshot_20240101-101010_Chrome.jpg': DateTime(2024, 1, 1, 10, 10, 10),
      'photo 2019.05.04.jpg': DateTime(2019, 5, 4, 12),
    };
    cases.forEach((name, expected) {
      test(name, () => expect(parseFilenameDate(name), expected));
    });

    test('no date or invalid dates', () {
      for (final name in [
        null,
        '',
        'IMG_0001.JPG',
        'cat.png',
        '1721327700123.jpg', // epoch millis, not a calendar date
        'IMG_20260230_101010.jpg', // 30 February
        'IMG_20261318_101010.jpg', // month 13
        'scan_120260718.jpg', // part of a longer digit run
        'IMG_2026-07_18.jpg', // inconsistent separators
      ]) {
        expect(parseFilenameDate(name), isNull, reason: '$name');
      }
    });

    test('invalid time falls back to date-only', () {
      expect(parseFilenameDate('IMG_20260718_256199.jpg'), DateTime(2026, 7, 18, 12));
    });
  });

  group('chooseCreatedAt', () {
    final now = DateTime(2026, 11, 23, 12);

    test('restored/copied file: filename date replaces the copy time', () {
      final copiedAt = DateTime(2026, 11, 20, 8); // DATE_ADDED
      final fromName = DateTime(2026, 7, 18, 20, 15);
      expect(chooseCreatedAt(mediaStoreCreated: copiedAt, filenameDate: fromName, now: now),
          fromName);
    });

    test('real DATE_TAKEN that matches the filename is kept (precision, time zone)', () {
      final taken = DateTime(2026, 7, 18, 22, 15, 3); // e.g. UTC offset vs name
      final fromName = DateTime(2026, 7, 18, 20, 15);
      expect(chooseCreatedAt(mediaStoreCreated: taken, filenameDate: fromName, now: now), taken);
      final dateOnly = DateTime(2026, 7, 18, 12);
      expect(chooseCreatedAt(mediaStoreCreated: taken, filenameDate: dateOnly, now: now), taken);
    });

    test('no filename date keeps MediaStore', () {
      final t = DateTime(2025, 1, 1);
      expect(chooseCreatedAt(mediaStoreCreated: t, filenameDate: null, now: now), t);
    });

    test('implausible filename dates are ignored', () {
      final added = DateTime(2026, 11, 20);
      // Before 1990.
      expect(
          chooseCreatedAt(mediaStoreCreated: added, filenameDate: DateTime(1985, 1, 1), now: now),
          added);
      // In the future.
      expect(
          chooseCreatedAt(mediaStoreCreated: DateTime(2027, 6, 1),
              filenameDate: DateTime(2027, 1, 1), now: now),
          DateTime(2027, 6, 1));
      // After the date the file was added.
      expect(
          chooseCreatedAt(mediaStoreCreated: added, filenameDate: DateTime(2026, 11, 22), now: now),
          added);
    });
  });
}
