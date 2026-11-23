import 'package:flutter/material.dart';

/// An example query the user can tap to run. Shows only the query text,
/// never a result.
class QueryChip extends StatelessWidget {
  const QueryChip({super.key, required this.query, required this.onSelected, this.icon});

  final String query;
  final ValueChanged<String> onSelected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: icon == null ? null : Icon(icon, size: 18, color: scheme.primary),
      label: Text(query),
      tooltip: 'Search for “$query”',
      onPressed: () => onSelected(query),
    );
  }
}
