import 'package:ai_gallery/core/design/app_colors.dart';
import 'package:ai_gallery/core/design/app_theme.dart';
import 'package:ai_gallery/core/design/tokens.dart';
import 'package:ai_gallery/core/widgets/format.dart';
import 'package:ai_gallery/core/widgets/highlighted_text.dart';
import 'package:ai_gallery/core/widgets/indexing_status_card.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('theme', () {
    test('light and dark themes build with semantic colors', () {
      for (final t in [AppTheme.light(), AppTheme.dark()]) {
        expect(t.useMaterial3, isTrue);
        expect(t.extension<AppSemanticColors>(), isNotNull);
      }
      expect(AppTheme.dark().brightness, Brightness.dark);
    });

    test('primary text has at least 4.5:1 contrast on surface', () {
      for (final t in [AppTheme.light(), AppTheme.dark()]) {
        final s = t.colorScheme;
        expect(_contrast(s.onSurface, s.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(s.onSurfaceVariant, s.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
      }
    });
  });

  test('grid columns grow with width', () {
    expect(AppLayout.gridColumns(320), 2);
    expect(AppLayout.gridColumns(400), 3);
    expect(AppLayout.gridColumns(700), 4);
    expect(AppLayout.gridColumns(1000), 5);
    expect(AppLayout.gridColumns(1400), 6);
  });

  group('format', () {
    test('bytes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(12 * 1024 * 1024), '12.0 MB');
    });

    test('relative time', () {
      final now = DateTime(2025, 6, 3, 12);
      expect(formatRelative(now.subtract(const Duration(seconds: 10)), now: now), 'just now');
      expect(formatRelative(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
      expect(formatRelative(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
      expect(formatRelative(now.subtract(const Duration(days: 1)), now: now), 'yesterday');
    });

    test('photo plural', () {
      expect(pluralPhotos(1), '1 photo');
      expect(pluralPhotos(1204), '1,204 photos');
    });
  });

  group('HighlightedText.segments', () {
    test('case-insensitive matches', () {
      expect(HighlightedText.segments('Hi Jamie, jamie here', ['JAMIE']), [
        ('Hi ', false),
        ('Jamie', true),
        (', ', false),
        ('jamie', true),
        (' here', false),
      ]);
    });

    test('no terms returns whole text', () {
      expect(HighlightedText.segments('abc', []), [('abc', false)]);
    });

    test('regex characters are escaped and longer terms win', () {
      expect(HighlightedText.segments(r'pay $5 (now)', [r'$5', '(now)', 'no']), [
        ('pay ', false),
        (r'$5', true),
        (' ', false),
        ('(now)', true),
      ]);
    });
  });

  group('IndexingStatusView.from', () {
    const stats = IndexStats(
      indexedImages: 1200,
      screenshots: 300,
      imagesWithText: 500,
      imagesWithEmbedding: 1200,
      databaseBytes: 1000,
    );

    test('indexing shows X of Y and pause', () {
      final v = IndexingStatusView.from(
        const IndexingProgress(phase: IndexingPhase.indexing, total: 400, processed: 100),
        stats,
      );
      expect(v.message, contains('100 of 400'));
      expect(v.progress, closeTo(0.25, 1e-9));
      expect(v.action, StatusAction.pause);
    });

    test('paused offers resume', () {
      final v = IndexingStatusView.from(const IndexingProgress(phase: IndexingPhase.paused, total: 4, processed: 1), stats);
      expect(v.action, StatusAction.resume);
    });

    test('completed shows count and failed line', () {
      final v = IndexingStatusView.from(const IndexingProgress(phase: IndexingPhase.completed, failed: 2), stats);
      expect(v.title, '1,200 photos ready to search');
      expect(v.details, contains('2'));
      expect(v.tone, StatusTone.success);
    });

    test('error and permission denied', () {
      expect(IndexingStatusView.from(const IndexingProgress(phase: IndexingPhase.error), stats).action,
          StatusAction.retry);
      expect(IndexingStatusView.from(const IndexingProgress(phase: IndexingPhase.permissionDenied), stats).action,
          StatusAction.allowAccess);
    });

    test('idle with empty index invites start', () {
      final v = IndexingStatusView.from(IndexingProgress.idle, IndexStats.empty);
      expect(v.title, 'Get your photos ready');
      expect(v.action, StatusAction.start);
    });
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
