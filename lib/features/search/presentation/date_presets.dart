import 'package:intl/intl.dart';

import '../../../domain/models.dart';

/// Date filter choices offered in the search filter bar.
enum DatePreset { anyTime, today, thisWeek, thisMonth, thisYear, custom }

extension DatePresetLabel on DatePreset {
  String get label => switch (this) {
        DatePreset.anyTime => 'Any time',
        DatePreset.today => 'Today',
        DatePreset.thisWeek => 'This week',
        DatePreset.thisMonth => 'This month',
        DatePreset.thisYear => 'This year',
        DatePreset.custom => 'Custom range…',
      };
}

/// Range for a fixed preset relative to [now]. Weeks start on Monday.
/// Returns null for [DatePreset.anyTime] and [DatePreset.custom].
DateRange? rangeForPreset(DatePreset preset, DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  return switch (preset) {
    DatePreset.today => DateRange(day, DateTime(now.year, now.month, now.day + 1), label: 'Today'),
    DatePreset.thisWeek => DateRange(
        DateTime(now.year, now.month, now.day - (now.weekday - DateTime.monday)),
        DateTime(now.year, now.month, now.day - (now.weekday - DateTime.monday) + 7),
        label: 'This week',
      ),
    DatePreset.thisMonth =>
      DateRange(DateTime(now.year, now.month), DateTime(now.year, now.month + 1), label: 'This month'),
    DatePreset.thisYear => DateRange(DateTime(now.year), DateTime(now.year + 1), label: 'This year'),
    DatePreset.anyTime || DatePreset.custom => null,
  };
}

/// Range from a picked first/last day (both inclusive) → exclusive end.
DateRange customRange(DateTime firstDay, DateTime lastDay) {
  final start = DateTime(firstDay.year, firstDay.month, firstDay.day);
  final end = DateTime(lastDay.year, lastDay.month, lastDay.day + 1);
  final String label;
  if (start.year == lastDay.year && start.month == lastDay.month && start.day == lastDay.day) {
    label = DateFormat.yMMMd().format(start);
  } else if (start.year == lastDay.year) {
    label = '${DateFormat.MMMd().format(start)} – ${DateFormat.yMMMd().format(lastDay)}';
  } else {
    label = '${DateFormat.yMMMd().format(start)} – ${DateFormat.yMMMd().format(lastDay)}';
  }
  return DateRange(start, end, label: label);
}
