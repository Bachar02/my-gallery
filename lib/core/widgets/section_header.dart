import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Section title with an optional trailing action (e.g. "Clear").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.padding});

  final String title;
  final Widget? action;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.only(top: AppSpace.lg, bottom: AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
