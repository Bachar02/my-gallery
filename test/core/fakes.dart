// Test doubles for the domain interfaces plus a helper that pumps a screen
// inside a ProviderScope with all UI-facing providers overridden.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_gallery/app/providers.dart';
import 'package:ai_gallery/core/design/app_theme.dart';
import 'package:ai_gallery/domain/interfaces.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// A valid 1x1 transparent PNG.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

GalleryImage fakeImage(
  String id, {
  ImageKind kind = ImageKind.photo,
  DateTime? createdAt,
  String? filename,
}) {
  final t = createdAt ?? DateTime(2025, 6, 3, 14, 5);
  return GalleryImage(
    id: id,
    width: 1080,
    height: 2400,
    createdAt: t,
    modifiedAt: t,
    kind: kind,
    filename: filename ?? 'IMG_$id.jpg',
    relativePath: kind == ImageKind.screenshot ? 'Pictures/Screenshots/' : 'DCIM/Camera/',
    mimeType: 'image/jpeg',
  );
}

class FakeGalleryRepository implements GalleryRepository {
  FakeGalleryRepository({
    this.permission = GalleryPermission.granted,
    GalleryPermission? requestResult,
    Map<String, GalleryImage>? images,
  })  : requestResult = requestResult ?? permission,
        images = images ?? {};

  GalleryPermission permission;
  GalleryPermission requestResult;
  Map<String, GalleryImage> images;
  Object? statusError;
  Object? requestError;

  /// Ids whose displayImage returns null even though getImage succeeds.
  final Set<String> undecodable = {};

  int requestCalls = 0;
  int openSettingsCalls = 0;
  int manageLimitedCalls = 0;

  @override
  Future<GalleryPermission> permissionStatus() async {
    if (statusError != null) throw statusError!;
    return permission;
  }

  @override
  Future<GalleryPermission> requestPermission() async {
    requestCalls++;
    if (requestError != null) throw requestError!;
    permission = requestResult;
    return permission;
  }

  @override
  Future<void> openAppSettings() async => openSettingsCalls++;

  @override
  Future<void> manageLimitedSelection() async => manageLimitedCalls++;

  @override
  Stream<List<GalleryImage>> listAllImages({int pageSize = 200}) => Stream.value(images.values.toList());

  @override
  Future<int> countImages() async => images.length;

  @override
  Future<GalleryImage?> getImage(String id) async => images[id];

  /// Requested thumbnail sizes by id; set [thumbnailBytes] to return images.
  final thumbnailRequests = <String, List<int>>{};
  Uint8List? thumbnailBytes;

  @override
  Future<Uint8List?> thumbnail(String id, {int size = 256}) async {
    (thumbnailRequests[id] ??= []).add(size);
    return thumbnailBytes;
  }

  @override
  Future<Uint8List?> displayImage(String id, {int maxSide = 2048}) async =>
      images.containsKey(id) && !undecodable.contains(id) ? tinyPng : null;

  @override
  Future<File?> originalFile(String id) async => null;

  @override
  Stream<void> get changes => const Stream.empty();
}

class FakeImageActions implements ImageActions {
  final shared = <GalleryImage>[];
  Object? error;

  @override
  Future<void> share(GalleryImage image) async {
    if (error != null) throw error!;
    shared.add(image);
  }
}

class FakeIndexStore implements IndexStore {
  FakeIndexStore({List<String>? recent, this.statsValue = IndexStats.empty}) : recent = recent ?? [];

  @override
  Future<Map<String, ScreenInfo>> screenInfos({
    Set<ScreenType> types = const {},
    SearchFilters filters = SearchFilters.none,
  }) async =>
      const {};

  List<String> recent;
  IndexStats statsValue;
  Object? statsError;
  Object? clearAllError;
  int clearAllCalls = 0;
  int statsCalls = 0;

  @override
  Future<IndexStats> stats() async {
    statsCalls++;
    if (statsError != null) throw statsError!;
    return statsValue;
  }

  @override
  Future<void> clearAll() async {
    clearAllCalls++;
    if (clearAllError != null) throw clearAllError!;
    recent = [];
    statsValue = IndexStats.empty;
  }

  @override
  Future<void> addRecentSearch(String query) async {
    recent.remove(query);
    recent.insert(0, query);
  }

  @override
  Future<List<String>> recentSearches({int limit = 8}) async => recent.take(limit).toList();

  @override
  Future<void> clearRecentSearches() async => recent = [];

  final settings = <String, String>{};

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String? value) async {
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} not faked');
}

class FakeIndexingService implements IndexingService {
  FakeIndexingService([this._current = IndexingProgress.idle]);

  final _controller = StreamController<IndexingProgress>.broadcast();
  IndexingProgress _current;
  int startCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;

  void emit(IndexingProgress p) {
    _current = p;
    _controller.add(p);
  }

  @override
  Stream<IndexingProgress> get progress => _controller.stream;

  @override
  IndexingProgress get current => _current;

  @override
  Future<void> start() async => startCalls++;

  @override
  void pause() => pauseCalls++;

  @override
  void resume() => resumeCalls++;

  @override
  Future<void> stop() async => stopCalls++;
}

ParsedQuery parsed(String raw, {DateRange? dateRange, ImageKind? kind}) => ParsedQuery(
      raw: raw,
      semanticText: raw,
      keywords: raw.toLowerCase().split(' ').where((w) => w.isNotEmpty).toList(),
      dateRange: dateRange,
      kind: kind,
    );

class FakeSearchEngine implements SearchEngine {
  FakeSearchEngine({this.results = const [], this.semantic = true});

  List<SearchResult> results;
  bool semantic;
  Object? error;
  ParsedQuery Function(String q)? parse;
  final calls = <(String, SearchFilters)>[];

  @override
  Future<SearchResponse> search(String query, {SearchFilters filters = SearchFilters.none}) async {
    calls.add((query, filters));
    if (error != null) throw error!;
    return SearchResponse(
      query: parse?.call(query) ?? parsed(query),
      results: results,
      elapsed: const Duration(milliseconds: 120),
      semanticSearchUsed: semantic,
    );
  }
}

/// Bundle of fakes with matching provider overrides.
class TestEnv {
  TestEnv({
    FakeGalleryRepository? gallery,
    FakeIndexStore? store,
    FakeIndexingService? indexing,
    FakeSearchEngine? search,
    FakeImageActions? actions,
  })  : gallery = gallery ?? FakeGalleryRepository(),
        store = store ?? FakeIndexStore(),
        indexing = indexing ?? FakeIndexingService(),
        search = search ?? FakeSearchEngine(),
        actions = actions ?? FakeImageActions();

  final FakeGalleryRepository gallery;
  final FakeIndexStore store;
  final FakeIndexingService indexing;
  final FakeSearchEngine search;
  final FakeImageActions actions;

  List<Override> get overrides => [
        galleryRepositoryProvider.overrideWithValue(gallery),
        indexStoreProvider.overrideWithValue(store),
        indexingServiceProvider.overrideWithValue(indexing),
        searchEngineProvider.overrideWithValue(search),
        imageActionsProvider.overrideWithValue(actions),
      ];

  /// Wraps [home] in a ProviderScope + MaterialApp with the app theme.
  Widget wrap(Widget home, {ThemeData? theme, double textScale = 1}) => ProviderScope(
        overrides: overrides,
        retry: (_, _) => null,
        child: MaterialApp(
          theme: theme ?? AppTheme.light(),
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: home,
          ),
        ),
      );
}

/// Scrolls [finder] into view, then taps it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
}
