/// Capture dates recovered from filenames, for images whose MediaStore
/// DATE_TAKEN is missing (restored backups, messenger downloads, PC copies).
library;

/// `YYYY[sep]MM[sep]DD`, optionally followed by `HH[sep]MM[sep]SS` and up to
/// three millisecond digits. The date separator (`-`, `_`, `.` or none) must
/// be consistent. Not part of a longer digit run.
final _datePattern = RegExp(
  r'(?<!\d)((?:19|20)\d{2})([-_.]?)(0[1-9]|1[0-2])\2(0[1-9]|[12]\d|3[01])'
  r'(?:[-_ T.]?([01]\d|2[0-3])[-_.:]?([0-5]\d)[-_.:]?([0-5]\d)\d{0,3}(?!\d)|(?!\d))',
);

/// Parses a capture date from a filename, in local time.
///
/// Handles `IMG_20260718_201500.jpg`, `IMG-20260718-WA0001.jpg`,
/// `Screenshot_20261020-090210.png`,
/// `Screenshot_2026-10-20-09-02-10-123_com.app.png`,
/// `PXL_20260718_201500123.jpg`, `VID_20260718.mp4`,
/// `signal-2026-07-18-201500.jpg` and `2026-07-18 20.15.00.jpg`.
/// Without a time, returns midday of that day (date-only precision).
/// Returns null when no valid calendar date is found.
DateTime? parseFilenameDate(String? filename) {
  if (filename == null || filename.isEmpty) return null;
  for (final m in _datePattern.allMatches(filename)) {
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(3)!);
    final d = int.parse(m.group(4)!);
    final hasTime = m.group(5) != null;
    final h = hasTime ? int.parse(m.group(5)!) : 12;
    final mi = hasTime ? int.parse(m.group(6)!) : 0;
    final s = hasTime ? int.parse(m.group(7)!) : 0;
    final dt = DateTime(y, mo, d, h, mi, s);
    // Reject dates that roll over (e.g. 2026-02-30).
    if (dt.year == y && dt.month == mo && dt.day == d) return dt;
  }
  return null;
}

/// Earliest capture date considered plausible.
final _minPlausible = DateTime(1990);

/// Below this gap the MediaStore date is assumed to be the real capture time
/// (it has full precision and the right time zone). Above it, the two dates
/// disagree and MediaStore's value is treated as the copy time.
const filenameDateTolerance = Duration(hours: 36);

/// Chooses `GalleryImage.createdAt`.
///
/// photo_manager reports DATE_TAKEN, or DATE_ADDED when DATE_TAKEN is null,
/// in one field ([mediaStoreCreated]); it cannot tell which one it used, and
/// asking would cost a query per image. The rule is:
///
/// * a filename date is used only if it is plausible: not before 1990, not
///   in the future, and not after [mediaStoreCreated] (+ tolerance). When
///   DATE_TAKEN is null, [mediaStoreCreated] is DATE_ADDED, so this enforces
///   "not after the date the file was added";
/// * and only if it is more than [filenameDateTolerance] earlier than
///   [mediaStoreCreated]. A real DATE_TAKEN matches the filename (cameras
///   name files at capture), so it is kept; a large gap means the value is
///   the copy/restore time.
DateTime chooseCreatedAt({
  required DateTime mediaStoreCreated,
  required DateTime? filenameDate,
  DateTime? now,
}) {
  if (filenameDate == null) return mediaStoreCreated;
  final current = now ?? DateTime.now();
  if (filenameDate.isBefore(_minPlausible)) return mediaStoreCreated;
  if (filenameDate.isAfter(current.add(filenameDateTolerance))) return mediaStoreCreated;
  if (filenameDate.isAfter(mediaStoreCreated.add(filenameDateTolerance))) {
    return mediaStoreCreated;
  }
  final gap = mediaStoreCreated.difference(filenameDate);
  return gap > filenameDateTolerance ? filenameDate : mediaStoreCreated;
}
