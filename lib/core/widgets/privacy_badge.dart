import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Quiet reassurance line: "Private · Everything stays on this phone".
class PrivacyBadge extends StatelessWidget {
  const PrivacyBadge({super.key, this.text = 'Searches run on this phone. Nothing is uploaded.'});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.lock_outline, size: 16, color: color),
        const SizedBox(width: AppSpace.xs),
        Flexible(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color))),
      ],
    );
  }
}
