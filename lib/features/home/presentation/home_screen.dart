import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/design/app_colors.dart';
import '../../../core/design/tokens.dart';
import '../../../core/widgets/app_search_field.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/indexing_status_card.dart';
import '../../../core/widgets/privacy_badge.dart';
import '../../../core/widgets/query_chip.dart';
import '../../../core/widgets/section_header.dart';
import '../../../domain/models.dart';
import '../../onboarding/presentation/permission_controller.dart';
import '../../search/presentation/search_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import 'indexing_controller.dart';
import 'recent_searches_controller.dart';

/// Example queries shown as chips. They only fill in the search box;
/// they never stand for results.
const exampleQueries = [
  'Screenshots from last week',
  'Restaurant menu',
  'Wi-Fi password',
  'Receipt from this month',
  'A red car',
  'Boarding pass',
];

String greetingFor(DateTime now) {
  final h = now.hour;
  if (h >= 5 && h < 12) return 'Good morning';
  if (h >= 12 && h < 18) return 'Good afternoon';
  return 'Good evening';
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  void _openSearch(BuildContext context, {String? query}) {
    Navigator.of(context).push(SearchScreen.route(initialQuery: query));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final permission = ref.watch(galleryPermissionProvider).value;

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.xs, AppSpace.gutter, AppSpace.xl),
              sliver: SliverToBoxAdapter(
                child: ContentWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.image_search, color: scheme.primary),
                          const SizedBox(width: AppSpace.xs),
                          Expanded(child: Text('AI Gallery', style: theme.textTheme.titleMedium)),
                          IconButton(
                            tooltip: 'Settings',
                            icon: const Icon(Icons.settings_outlined),
                            onPressed: () => Navigator.of(context).push(SettingsScreen.route()),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.lg),
                      Text(
                        greetingFor(DateTime.now()),
                        style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      Semantics(
                        header: true,
                        child: Text('What are you looking for?', style: theme.textTheme.headlineMedium),
                      ),
                      const SizedBox(height: AppSpace.md),
                      AppSearchField(readOnly: true, onTap: () => _openSearch(context)),
                      const SizedBox(height: AppSpace.xs),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpace.xs),
                        child: PrivacyBadge(),
                      ),
                      if (permission == GalleryPermission.limited) ...[
                        const SizedBox(height: AppSpace.md),
                        const LimitedAccessBanner(),
                      ],
                      const SizedBox(height: AppSpace.md),
                      const HomeIndexingStatus(),
                      const SectionHeader('Try asking'),
                      Wrap(
                        spacing: AppSpace.xs,
                        runSpacing: AppSpace.xs,
                        children: [
                          for (final q in exampleQueries)
                            QueryChip(query: q, onSelected: (q) => _openSearch(context, query: q)),
                        ],
                      ),
                      _RecentSearches(onSelected: (q) => _openSearch(context, query: q)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Indexing status card wired to the indexing providers.
class HomeIndexingStatus extends ConsumerWidget {
  const HomeIndexingStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(indexingProgressProvider);
    final stats = ref.watch(indexStatsProvider).value;
    final deleted = ref.watch(indexingDisabledProvider).value ?? false;

    if (progress.hasError && !progress.hasValue) {
      return IndexingStatusCard(
        view: const IndexingStatusView(
          title: 'Couldn’t read indexing status',
          message: 'Search still works for photos already prepared.',
          icon: Icons.error_outline,
          tone: StatusTone.error,
          action: StatusAction.retry,
        ),
        onAction: (_) => ref.invalidate(indexingProgressProvider),
      );
    }
    final value = progress.value;
    if (value == null) return const IndexingStatusCardSkeleton();

    return IndexingStatusCard(
      view: IndexingStatusView.from(value, stats, indexDeleted: deleted),
      onAction: (action) => handleStatusAction(context, ref, action),
    );
  }
}

/// Shared by Home and Settings.
Future<void> handleStatusAction(BuildContext context, WidgetRef ref, StatusAction action) async {
  final actions = ref.read(indexingActionsProvider);
  switch (action) {
    case StatusAction.start:
    case StatusAction.retry:
      unawaited(actions.start());
    case StatusAction.pause:
      actions.pause();
    case StatusAction.resume:
      actions.resume();
    case StatusAction.rebuild:
      unawaited(actions.rebuild());
    case StatusAction.allowAccess:
      final messenger = ScaffoldMessenger.of(context);
      try {
        final result = await ref.read(galleryPermissionProvider.notifier).request();
        if (result.canBrowse) unawaited(actions.autoStart());
      } catch (_) {
        messenger.showSnackBar(const SnackBar(content: Text('Couldn’t request photo access. Please try again.')));
      }
  }
}

/// Explains Android "selected photos only" access and lets the user change it.
class LimitedAccessBanner extends ConsumerWidget {
  const LimitedAccessBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = AppSemanticColors.of(context);
    return Card(
      color: colors.warningContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.photo_library_outlined, color: colors.onWarningContainer),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'You’ve shared only some photos. AI Gallery can search just those.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: colors.onWarningContainer),
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: colors.onWarningContainer),
                onPressed: () => manageLimitedSelection(context, ref),
                child: const Text('Change selection'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the system picker for limited access, then re-syncs the index.
Future<void> manageLimitedSelection(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final actions = ref.read(indexingActionsProvider);
  try {
    await ref.read(galleryPermissionProvider.notifier).manageLimitedSelection();
    await ref.read(galleryPermissionProvider.notifier).refresh();
    unawaited(actions.autoStart());
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('Couldn’t open the photo picker. Please try again.')));
  }
}

class _RecentSearches extends ConsumerWidget {
  const _RecentSearches({required this.onSelected});
  final ValueChanged<String> onSelected;

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(recentSearchesProvider.notifier).clear();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Couldn’t clear recent searches. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentSearchesProvider).value ?? const <String>[];
    if (recent.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Recent searches',
          action: TextButton(onPressed: () => _clear(context, ref), child: const Text('Clear')),
        ),
        for (final q in recent)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
            leading: const Icon(Icons.history),
            title: Text(q, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.north_west, size: 18),
            onTap: () => onSelected(q),
          ),
      ],
    );
  }
}
