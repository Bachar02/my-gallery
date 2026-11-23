/// Small, locale-aware formatting helpers shared by screens.
library;

import 'package:intl/intl.dart';

import '../../domain/models.dart';

String formatCount(int n) => NumberFormat.decimalPattern().format(n);

/// "1 photo" / "1,204 photos".
String pluralPhotos(int n) => n == 1 ? '1 photo' : '${formatCount(n)} photos';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// "3 Jun 2025".
String formatShortDate(DateTime t) => DateFormat.yMMMd().format(t);

/// "3 June 2025 at 14:05" style (locale dependent).
String formatLongDateTime(DateTime t) => '${DateFormat.yMMMMd().format(t)}, ${DateFormat.jm().format(t)}';

/// "just now", "5 min ago", "3 h ago", "yesterday", or a date.
String formatRelative(DateTime t, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final diff = current.difference(t);
  if (diff.isNegative || diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays == 1) return 'yesterday';
  if (diff.inDays < 7) return '${diff.inDays} days ago';
  return formatShortDate(t);
}

String kindLabel(ImageKind kind) => switch (kind) {
      ImageKind.screenshot => 'Screenshot',
      ImageKind.photo => 'Photo',
    };

String kindPluralLabel(ImageKind kind) => switch (kind) {
      ImageKind.screenshot => 'Screenshots',
      ImageKind.photo => 'Photos',
    };
