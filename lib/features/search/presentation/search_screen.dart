import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/design/tokens.dart';
import '../../../core/widgets/app_search_field.dart';
import '../../../core/widgets/filter_bar.dart';
import '../../../core/widgets/format.dart';
import '../../../core/widgets/gallery_thumbnail.dart';
import '../../../core/widgets/query_chip.dart';
import '../../../core/widgets/skeleton.dart';
import '../../../core/widgets/state_views.dart';
import '../../../domain/models.dart';
import '../../viewer/presentation/viewer_screen.dart';
import 'date_presets.dart';
import 'search_controller.dart';

const _searchTipsQueries = ['Screenshot with an address', 'Menu from last summer', 'Photos of a beach'];

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialQuery});

  /// When set, the search runs immediately (e.g. from a suggestion chip).
  final String? initialQuery;

  static Route<void> route({String? initialQuery}) =>
      MaterialPageRoute(builder: (_) => SearchScreen(initialQuery: initialQuery));

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _text = TextEditingController(text: widget.initialQuery ?? '');
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery;
    if (initial != null && initial.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(searchControllerProvider.notifier).submit(initial);
      });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String q) {
    _focus.unfocus();
    ref.read(searchControllerProvider.notifier).submit(q);
  }

  void _runExample(String q) {
    _text.text = q;
    _submit(q);
  }

  Future<void> _pickDate() async {
    final state = ref.read(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);
    final picked = await showModalBottomSheet<DatePreset>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.xs),
                child: Semantics(
                  header: true,
                  child: Text('When was it taken?', style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
              for (final p in DatePreset.values)
                ListTile(
                  title: Text(p == DatePreset.custom && state.datePreset == DatePreset.custom
                      ? state.dateRange?.label ?? p.label
                      : p.label),
                  selected: state.datePreset == p,
                  trailing: state.datePreset == p ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.of(context).pop(p),
                ),
              const SizedBox(height: AppSpace.xs),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked != DatePreset.custom) {
      await controller.setDatePreset(picked);
      return;
    }
    final now = DateTime.now();
    final current = state.datePreset == DatePreset.custom ? state.dateRange : null;
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: current == null
          ? null
          : DateTimeRange(start: current.start, end: current.end.subtract(const Duration(days: 1))),
      helpText: 'Choose dates',
    );
    if (range == null) return;
    await controller.setDatePreset(DatePreset.custom, custom: customRange(range.start, range.end));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);
    final dateLabel = state.dateRange?.label ?? DatePreset.anyTime.label;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.xxs, AppSpace.xs, AppSpace.gutter, AppSpace.xs),
              child: Row(
                children: [
                  const BackButton(),
                  Expanded(
                    child: AppSearchField(
                      controller: _text,
                      focusNode: _focus,
                      autofocus: widget.initialQuery == null,
                      onSubmitted: _submit,
                    ),
                  ),
                ],
              ),
            ),
            SearchFilterBar(
              dateLabel: dateLabel,
              dateActive: state.dateRange != null,
              onDateTap: _pickDate,
              kind: state.kind,
              onKindChanged: controller.setKind,
            ),
            const SizedBox(height: AppSpace.xs),
            if (state.status == SearchStatus.loading && state.response != null)
              const LinearProgressIndicator(minHeight: 2, semanticsLabel: 'Searching')
            else
              const SizedBox(height: 2),
            Expanded(child: _body(context, state)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, SearchState state) {
    final controller = ref.read(searchControllerProvider.notifier);
    switch (state.status) {
      case SearchStatus.idle:
        return MessageView(
          icon: Icons.manage_search,
          title: 'Describe what you remember',
          message: 'Words that appear in the image, what’s in it, or roughly when you took it. '
              'You can combine them, like “screenshots of receipts from March”.',
          details: Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpace.xs,
            runSpacing: AppSpace.xs,
            children: [for (final q in _searchTipsQueries) QueryChip(query: q, onSelected: _runExample)],
          ),
        );
      case SearchStatus.failure:
        return ErrorView(
          title: 'Search didn’t work',
          message: 'Something went wrong while searching. Your photos are fine — please try again.',
          onRetry: controller.retry,
        );
      case SearchStatus.loading when state.response == null:
        return const _ResultsSkeleton();
      case SearchStatus.loading:
      case SearchStatus.success:
        final response = state.response!;
        if (response.results.isEmpty) return _NoResults(state: state, onClearFilters: controller.clearFilters);
        return _Results(response: response, state: state);
    }
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.response, required this.state});

  final SearchResponse response;
  final SearchState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final interpretation = interpretationOf(response.query, state.filters);
    final count = response.results.length;
    final seconds = (response.elapsed.inMilliseconds / 1000).toStringAsFixed(1);

    return LayoutBuilder(builder: (context, constraints) {
      final columns = AppLayout.gridColumns(constraints.maxWidth);
      const spacing = AppSpace.xs;
      final tileWidth = (constraints.maxWidth - AppSpace.gutter * 2 - spacing * (columns - 1)) / columns;
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.xs, AppSpace.gutter, AppSpace.sm),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!response.semanticSearchUsed) ...[const TextOnlyNotice(), const SizedBox(height: AppSpace.sm)],
                  if (interpretation != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.xxs),
                      child: Row(
                        children: [
                          Icon(Icons.tune, size: 16, color: theme.colorScheme.primary),
                          const SizedBox(width: AppSpace.xs),
                          Expanded(child: Text('Understood as $interpretation', style: muted)),
                        ],
                      ),
                    ),
                  Semantics(
                    liveRegion: true,
                    child: Text(count == 1 ? '1 match · $seconds s' : '${formatCount(count)} matches · $seconds s',
                        style: muted),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xl),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: spacing,
                crossAxisSpacing: spacing,
                mainAxisExtent: tileWidth + ResultTile.captionHeight(context),
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => ResultTile(
                  result: response.results[i],
                  onTap: () => Navigator.of(context).push(ViewerScreen.route(results: response.results, initialIndex: i)),
                ),
                childCount: count,
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// "Screenshots · Summer 2025" from what the parser inferred, omitting parts
/// that merely repeat an explicit filter. Null when nothing was inferred.
String? interpretationOf(ParsedQuery query, SearchFilters filters) {
  final parts = <String>[];
  final kind = query.kind;
  if (kind != null && filters.kinds.isEmpty) parts.add(kindPluralLabel(kind));
  final range = query.dateRange;
  if (range != null && filters.dateRange == null) parts.add(range.label);
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Quiet notice shown when visual search was not used.
class TextOnlyNotice extends StatelessWidget {
  const TextOnlyNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              'Visual search isn’t available right now, so these results are based on text found '
              'in your images and file names.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends ConsumerWidget {
  const _NoResults({required this.state, required this.onClearFilters});

  final SearchState state;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(indexingProgressProvider).value;
    final stillIndexing = progress != null && (progress.isRunning || progress.phase == IndexingPhase.paused);
    final semanticUsed = state.response?.semanticSearchUsed ?? true;
    final q = state.query;
    return MessageView(
      icon: Icons.search_off,
      title: 'No matching photos',
      message: q.isEmpty
          ? 'Nothing in your photos matches these filters.'
          : 'Nothing in your photos clearly matches “$q”. AI Gallery only shows images it’s confident about.',
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stillIndexing)
            TipLine('Some photos are still being prepared '
                '(${formatCount(progress.processed)} of ${formatCount(progress.total)}). Try again when that finishes.'),
          const TipLine('Use fewer or simpler words, like “menu” instead of “the menu from that restaurant”.'),
          const TipLine('Try a word that appears in the image, such as a name, shop or website.'),
          if (!semanticUsed) const TipLine('Visual search is unavailable, so only text in images can be matched.'),
          if (state.hasFilters) const TipLine('Remove filters to search all your photos.'),
        ],
      ),
      action: state.hasFilters
          ? OutlinedButton.icon(
              onPressed: onClearFilters,
              icon: const Icon(Icons.filter_alt_off_outlined),
              label: const Text('Clear filters'),
            )
          : null,
    );
  }
}

class _ResultsSkeleton extends StatelessWidget {
  const _ResultsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Searching',
      liveRegion: true,
      child: LayoutBuilder(builder: (context, constraints) {
        final columns = AppLayout.gridColumns(constraints.maxWidth);
        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.xl, AppSpace.gutter, AppSpace.gutter),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpace.xs,
            crossAxisSpacing: AppSpace.xs,
          ),
          itemCount: columns * 4,
          itemBuilder: (_, _) => const SkeletonBox(),
        );
      }),
    );
  }
}
