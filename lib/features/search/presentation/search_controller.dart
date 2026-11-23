import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/widgets/filter_bar.dart';
import '../../../domain/models.dart';
import '../../home/presentation/recent_searches_controller.dart';
import 'date_presets.dart';

enum SearchStatus { idle, loading, success, failure }

class SearchState {
  const SearchState({
    this.query = '',
    this.datePreset = DatePreset.anyTime,
    this.dateRange,
    this.kind = KindFilter.all,
    this.status = SearchStatus.idle,
    this.response,
    this.error,
  });

  final String query;
  final DatePreset datePreset;
  final DateRange? dateRange;
  final KindFilter kind;
  final SearchStatus status;

  /// Latest successful response (kept while a new search loads).
  final SearchResponse? response;
  final Object? error;

  SearchFilters get filters => SearchFilters(
        dateRange: dateRange,
        kinds: switch (kind) {
          KindFilter.all => const {},
          KindFilter.screenshots => const {ImageKind.screenshot},
          KindFilter.photos => const {ImageKind.photo},
        },
      );

  bool get hasFilters => dateRange != null || kind != KindFilter.all;

  /// Something to search for: text or at least one filter.
  bool get canSearch => query.trim().isNotEmpty || hasFilters;

  SearchState copyWith({
    String? query,
    DatePreset? datePreset,
    DateRange? Function()? dateRange,
    KindFilter? kind,
    SearchStatus? status,
    SearchResponse? Function()? response,
    Object? Function()? error,
  }) =>
      SearchState(
        query: query ?? this.query,
        datePreset: datePreset ?? this.datePreset,
        dateRange: dateRange != null ? dateRange() : this.dateRange,
        kind: kind ?? this.kind,
        status: status ?? this.status,
        response: response != null ? response() : this.response,
        error: error != null ? error() : this.error,
      );
}

final searchControllerProvider = NotifierProvider.autoDispose<GallerySearchController, SearchState>(GallerySearchController.new);

class GallerySearchController extends Notifier<SearchState> {
  int _generation = 0;

  @override
  SearchState build() => const SearchState();

  /// Runs a search for [raw] with the current filters and records it in
  /// recent searches.
  Future<void> submit(String raw) async {
    final query = raw.trim();
    state = state.copyWith(query: query);
    if (query.isNotEmpty) unawaited(ref.read(recentSearchesProvider.notifier).add(query));
    await _run();
  }

  Future<void> setDatePreset(DatePreset preset, {DateRange? custom}) async {
    final range = preset == DatePreset.custom ? custom : rangeForPreset(preset, DateTime.now());
    if (preset == DatePreset.custom && custom == null) return;
    state = state.copyWith(datePreset: preset, dateRange: () => range);
    await _run();
  }

  Future<void> setKind(KindFilter kind) async {
    if (kind == state.kind) return;
    state = state.copyWith(kind: kind);
    await _run();
  }

  Future<void> clearFilters() async {
    state = state.copyWith(datePreset: DatePreset.anyTime, dateRange: () => null, kind: KindFilter.all);
    await _run();
  }

  Future<void> retry() => _run();

  Future<void> _run() async {
    final generation = ++_generation;
    if (!state.canSearch) {
      state = state.copyWith(status: SearchStatus.idle, response: () => null, error: () => null);
      return;
    }
    state = state.copyWith(status: SearchStatus.loading, error: () => null);
    try {
      final response = await ref.read(searchEngineProvider).search(state.query, filters: state.filters);
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(status: SearchStatus.success, response: () => response);
    } catch (e) {
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(status: SearchStatus.failure, error: () => e);
    }
  }
}
