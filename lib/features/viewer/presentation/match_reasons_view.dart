import 'package:flutter/material.dart';

import '../../../core/design/tokens.dart';
import '../../../core/widgets/highlighted_text.dart';
import '../../../domain/models.dart';

IconData iconForSignal(MatchSignal s) => switch (s) {
      MatchSignal.textInImage => Icons.text_fields,
      MatchSignal.visualContent => Icons.visibility_outlined,
      MatchSignal.date => Icons.calendar_today_outlined,
      MatchSignal.imageType => Icons.screenshot_outlined,
      MatchSignal.filename => Icons.insert_drive_file_outlined,
    };

/// Plain-language confidence; null when the signal has no strength.
String? strengthLabel(double? strength) {
  if (strength == null) return null;
  if (strength >= 0.75) return 'Strong match';
  if (strength >= 0.5) return 'Good match';
  return 'Possible match';
}

/// The "Why this matched" list for one result.
class MatchReasonsView extends StatelessWidget {
  const MatchReasonsView({super.key, required this.reasons});

  final List<MatchReason> reasons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in reasons)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(iconForSignal(r.signal), color: scheme.primary, size: 20),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.description, style: theme.textTheme.bodyLarge),
                      if (strengthLabel(r.strength) case final label?)
                        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      if (r.snippet != null && r.snippet!.trim().isNotEmpty) ...[
                        const SizedBox(height: AppSpace.xs),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(AppSpace.sm),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: HighlightedText(
                            '“${r.snippet!.trim()}”',
                            terms: r.matchedTerms,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
