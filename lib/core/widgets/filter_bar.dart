import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Image type choice shown in the filter bar.
enum KindFilter { all, screenshots, photos }

/// Horizontal bar with a date filter button and image-type choice chips.
class SearchFilterBar extends StatelessWidget {
  const SearchFilterBar({
    super.key,
    required this.dateLabel,
    required this.dateActive,
    required this.onDateTap,
    required this.kind,
    required this.onKindChanged,
  });

  final String dateLabel;
  final bool dateActive;
  final VoidCallback onDateTap;
  final KindFilter kind;
  final ValueChanged<KindFilter> onKindChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget kindChip(KindFilter value, String label) => Padding(
          padding: const EdgeInsets.only(right: AppSpace.xs),
          child: ChoiceChip(
            label: Text(label),
            selected: kind == value,
            showCheckmark: false,
            onSelected: (_) => onKindChanged(value),
          ),
        );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.xs),
            child: FilterChip(
              avatar: Icon(Icons.calendar_today_outlined, size: 18, color: dateActive ? null : scheme.primary),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [Text(dateLabel), const Icon(Icons.arrow_drop_down, size: 20)],
              ),
              tooltip: 'Filter by date',
              selected: dateActive,
              showCheckmark: false,
              onSelected: (_) => onDateTap(),
            ),
          ),
          SizedBox(height: 32, child: VerticalDivider(color: scheme.outlineVariant, width: AppSpace.md)),
          kindChip(KindFilter.all, 'All'),
          kindChip(KindFilter.screenshots, 'Screenshots'),
          kindChip(KindFilter.photos, 'Photos'),
        ],
      ),
    );
  }
}
