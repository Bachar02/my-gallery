import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../design/app_colors.dart';
import '../design/tokens.dart';
import 'format.dart';

enum StatusTone { neutral, working, success, warning, error }

enum StatusAction { start, pause, resume, retry, allowAccess, rebuild }

/// What the indexing status card shows for a given progress + stats.
/// Pure so it can be unit-tested.
class IndexingStatusView {
  const IndexingStatusView({
    required this.title,
    required this.message,
    required this.icon,
    required this.tone,
    this.showProgress = false,
    this.progress,
    this.action,
    this.details,
  });

  final String title;
  final String message;
  final IconData icon;
  final StatusTone tone;

  /// Whether to show a progress bar; [progress] null = indeterminate.
  final bool showProgress;
  final double? progress;
  final StatusAction? action;

  /// Optional secondary line (e.g. technical error message, failed count).
  final String? details;

  /// [indexDeleted]: the user deleted the local index and automatic
  /// indexing is off until they rebuild it.
  factory IndexingStatusView.from(IndexingProgress p, IndexStats? stats, {bool indexDeleted = false, DateTime? now}) {
    if (indexDeleted && !p.isRunning) {
      return const IndexingStatusView(
        title: 'Search index deleted',
        message: 'Nothing from your photos is stored, so search won’t find anything. '
            'Rebuild the index when you want to search again.',
        icon: Icons.delete_sweep_outlined,
        tone: StatusTone.neutral,
        action: StatusAction.rebuild,
      );
    }
    final indexed = stats?.indexedImages ?? 0;
    final last = p.lastCompletedAt ?? stats?.lastIndexedAt;
    final failedLine = p.failed > 0 ? '${formatCount(p.failed)} couldn’t be read and will be retried later.' : null;
    switch (p.phase) {
      case IndexingPhase.scanning:
        return const IndexingStatusView(
          title: 'Looking for new photos…',
          message: 'Checking your gallery for anything new or changed.',
          icon: Icons.manage_search,
          tone: StatusTone.working,
          showProgress: true,
        );
      case IndexingPhase.indexing:
        return IndexingStatusView(
          title: 'Preparing photos for search',
          message: '${formatCount(p.processed)} of ${formatCount(p.total)} · You can search while this runs.',
          icon: Icons.auto_awesome_outlined,
          tone: StatusTone.working,
          showProgress: true,
          progress: p.total == 0 ? null : p.fraction,
          action: StatusAction.pause,
        );
      case IndexingPhase.paused:
        return IndexingStatusView(
          title: 'Paused',
          message: '${formatCount(p.processed)} of ${formatCount(p.total)} prepared. Search covers what’s done so far.',
          icon: Icons.pause_circle_outline,
          tone: StatusTone.neutral,
          showProgress: true,
          progress: p.fraction,
          action: StatusAction.resume,
        );
      case IndexingPhase.completed:
        return IndexingStatusView(
          title: indexed > 0 ? '${pluralPhotos(indexed)} ready to search' : 'Your photos are ready to search',
          message: last != null ? 'Up to date · Updated ${formatRelative(last, now: now)}' : 'Up to date',
          icon: Icons.check_circle_outline,
          tone: StatusTone.success,
          details: failedLine,
        );
      case IndexingPhase.error:
        return IndexingStatusView(
          title: 'Preparing photos stopped',
          message: 'Something went wrong. Photos prepared so far can still be searched.',
          icon: Icons.error_outline,
          tone: StatusTone.error,
          action: StatusAction.retry,
          details: p.errorMessage,
        );
      case IndexingPhase.permissionDenied:
        return const IndexingStatusView(
          title: 'Photo access needed',
          message: 'AI Gallery can’t see your photos, so it can’t prepare them for search.',
          icon: Icons.no_photography_outlined,
          tone: StatusTone.warning,
          action: StatusAction.allowAccess,
        );
      case IndexingPhase.idle:
        if (indexed > 0) {
          return IndexingStatusView(
            title: '${pluralPhotos(indexed)} ready to search',
            message: last != null ? 'Last updated ${formatRelative(last, now: now)}' : 'Ready',
            icon: Icons.check_circle_outline,
            tone: StatusTone.success,
            action: StatusAction.start,
          );
        }
        return const IndexingStatusView(
          title: 'Get your photos ready',
          message: 'AI Gallery reads text and visual details on this phone so you can search by description.',
          icon: Icons.photo_library_outlined,
          tone: StatusTone.neutral,
          action: StatusAction.start,
        );
    }
  }
}

/// Card summarising indexing progress, with one contextual action.
class IndexingStatusCard extends StatelessWidget {
  const IndexingStatusCard({super.key, required this.view, required this.onAction});

  final IndexingStatusView view;
  final ValueChanged<StatusAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = AppSemanticColors.of(context);
    final (Color bg, Color fg) = switch (view.tone) {
      StatusTone.neutral => (scheme.surfaceContainerLow, scheme.primary),
      StatusTone.working => (scheme.surfaceContainerLow, scheme.primary),
      StatusTone.success => (scheme.surfaceContainerLow, semantic.success),
      StatusTone.warning => (semantic.warningContainer, semantic.onWarningContainer),
      StatusTone.error => (scheme.errorContainer, scheme.onErrorContainer),
    };
    final onBg = switch (view.tone) {
      StatusTone.warning => semantic.onWarningContainer,
      StatusTone.error => scheme.onErrorContainer,
      _ => scheme.onSurface,
    };

    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(view.icon, color: fg),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        liveRegion: true,
                        child: Text(view.title, style: theme.textTheme.titleMedium?.copyWith(color: onBg)),
                      ),
                      const SizedBox(height: AppSpace.xxs),
                      Text(view.message, style: theme.textTheme.bodyMedium?.copyWith(color: onBg)),
                      if (view.details != null) ...[
                        const SizedBox(height: AppSpace.xxs),
                        Text(
                          view.details!,
                          style: theme.textTheme.bodySmall?.copyWith(color: onBg.withValues(alpha: 0.8)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (view.showProgress) ...[
              const SizedBox(height: AppSpace.sm),
              LinearProgressIndicator(
                value: view.progress,
                semanticsLabel: 'Preparing photos',
                semanticsValue: view.progress == null ? null : '${(view.progress! * 100).round()}%',
              ),
            ],
            if (view.action != null) ...[
              const SizedBox(height: AppSpace.sm),
              Align(alignment: AlignmentDirectional.centerEnd, child: _actionButton(view.action!)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actionButton(StatusAction action) {
    final (String label, IconData icon) = switch (action) {
      StatusAction.start => ('Check for new photos', Icons.refresh),
      StatusAction.pause => ('Pause', Icons.pause),
      StatusAction.resume => ('Resume', Icons.play_arrow),
      StatusAction.retry => ('Try again', Icons.refresh),
      StatusAction.allowAccess => ('Allow access', Icons.photo_library_outlined),
      StatusAction.rebuild => ('Rebuild index', Icons.restart_alt),
    };
    void onPressed() => onAction(action);
    return switch (action) {
      StatusAction.allowAccess || StatusAction.retry || StatusAction.rebuild =>
        FilledButton.icon(onPressed: onPressed, icon: Icon(icon), label: Text(label)),
      _ => TextButton.icon(onPressed: onPressed, icon: Icon(icon), label: Text(label)),
    };
  }
}

/// Placeholder with the card's footprint while progress/stats load.
class IndexingStatusCardSkeleton extends StatelessWidget {
  const IndexingStatusCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Semantics(
            label: 'Loading indexing status',
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Bar(width: 180, height: 18),
                SizedBox(height: AppSpace.xs),
                _Bar(width: double.infinity, height: 14),
              ],
            ),
          ),
        ),
      );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.width, required this.height});
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      );
}
