import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/design/tokens.dart';
import '../../../core/widgets/gallery_thumbnail.dart';
import '../../../core/widgets/section_header.dart';
import '../../../domain/models.dart';

/// Developer view: how the query was understood and how each result was
/// scored, so a wrong result can be reported precisely. Shown only when the
/// hidden developer option is on. Everything stays on the device; "Copy
/// report" puts the breakdown on the clipboard (no file names or ids).
class ScoreBreakdownScreen extends StatelessWidget {
  const ScoreBreakdownScreen({super.key, required this.query, required this.response});

  final String query;
  final SearchResponse response;

  static Route<void> route({required String query, required SearchResponse response}) =>
      MaterialPageRoute(builder: (_) => ScoreBreakdownScreen(query: query, response: response));

  /// Plain-text report: query plan, then one block per result.
  static String report(String query, SearchResponse response) {
    final b = StringBuffer()
      ..writeln('Query: $query')
      ..writeln('Intent: ${response.intent.name}');
    for (final d in response.details) {
      b.writeln('  $d');
    }
    b.writeln('Results: ${response.primary.length} + ${response.mentions.length} mentions, '
        '${response.elapsed.inMilliseconds} ms');
    for (final (i, r) in response.results.indexed) {
      final date = r.image.createdAt.toIso8601String().substring(0, 10);
      b.writeln('#${i + 1} ${r.group.name} · ${r.image.kind.name} · $date · score ${r.score.toStringAsFixed(3)}');
      for (final d in r.details) {
        b.writeln('    $d');
      }
      for (final reason in r.reasons) {
        b.writeln('    reason: ${reason.description}');
      }
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Score breakdown'),
        actions: [
          IconButton(
            tooltip: 'Copy report',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report(query, response)));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report copied')));
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.gutter),
        children: [
          SectionHeader('“$query”'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Intent: ${response.intent.name}', style: theme.textTheme.titleSmall),
                  for (final d in response.details) Text(d.toString(), style: mono),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          for (final (i, r) in response.results.indexed)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: GalleryThumbnail(image: r.image),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('#${i + 1} · ${r.group == ResultGroup.mentions ? 'mention' : 'match'} · '
                              'score ${r.score.toStringAsFixed(3)}',
                              style: theme.textTheme.titleSmall),
                          for (final d in r.details) Text(d.toString(), style: mono),
                          for (final reason in r.reasons)
                            Text('• ${reason.description}', style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
