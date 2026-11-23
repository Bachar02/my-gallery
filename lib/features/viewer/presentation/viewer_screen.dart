import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/design/app_theme.dart';
import '../../../core/design/tokens.dart';
import '../../../core/widgets/format.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/state_views.dart';
import '../../../domain/models.dart';
import 'match_reasons_view.dart';
import 'viewer_providers.dart';

/// Full-screen viewer for search results with swipe between results,
/// pinch-zoom, share, metadata and "Why this matched".
class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({super.key, required this.results, this.initialIndex = 0});

  final List<SearchResult> results;
  final int initialIndex;

  static Route<void> route({required List<SearchResult> results, int initialIndex = 0}) =>
      MaterialPageRoute(builder: (_) => ViewerScreen(results: results, initialIndex: initialIndex));

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _share(GalleryImage image) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(imageActionsProvider).share(image);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Couldn’t open the share menu. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.results.length;
    final current = widget.results[_index];
    final loaded = ref.watch(viewerImageProvider(current.image.id)).value;

    return Theme(
      data: AppTheme.dark(),
      child: Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          backgroundColor: scheme.surfaceContainerLowest,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            elevation: 0,
            scrolledUnderElevation: 0,
            // Scrim keeps the counter and Share readable over bright or
            // text-heavy images without blocking the picture.
            flexibleSpace: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.6, 1],
                  colors: [Color(0xB3000000), Color(0x73000000), Color(0x00000000)],
                ),
              ),
            ),
            title: total > 1 ? Text('${_index + 1} of $total') : null,
            actions: [
              IconButton(
                tooltip: 'Share',
                icon: const Icon(Icons.share_outlined),
                onPressed: loaded == null ? null : () => _share(loaded.image),
              ),
            ],
          ),
          body: PageView.builder(
            controller: _pages,
            physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
            itemCount: total,
            onPageChanged: (i) => setState(() {
              _index = i;
              _zoomed = false;
            }),
            itemBuilder: (context, i) => _ViewerPage(
              key: ValueKey(widget.results[i].image.id),
              result: widget.results[i],
              onZoomChanged: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
            ),
          ),
        );
      }),
    );
  }
}

class _ViewerPage extends ConsumerStatefulWidget {
  const _ViewerPage({super.key, required this.result, required this.onZoomChanged});

  final SearchResult result;
  final ValueChanged<bool> onZoomChanged;

  @override
  ConsumerState<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends ConsumerState<_ViewerPage> {
  static const _minSheet = 0.14;
  final _transform = TransformationController();
  Offset _doubleTapAt = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(() {
      final z = _transform.value.getMaxScaleOnAxis() > 1.01;
      if (z != _zoomed) {
        _zoomed = z;
        widget.onZoomChanged(z);
      }
    });
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
    } else {
      const scale = 2.5;
      final p = _doubleTapAt;
      _transform.value = Matrix4.identity()
        ..translateByDouble(-p.dx * (scale - 1), -p.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.result.image.id;
    final async = ref.watch(viewerImageProvider(id));

    return switch (async) {
      AsyncData(value: final data?) => LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Positioned.fill(
                bottom: constraints.maxHeight * _minSheet,
                child: GestureDetector(
                  onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
                  onDoubleTap: _toggleZoom,
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: 1,
                    maxScale: 5,
                    child: Center(
                      child: Semantics(
                        image: true,
                        label: '${kindLabel(data.image.kind)} from ${formatShortDate(data.image.createdAt)}',
                        child: Image.memory(
                          data.bytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const MessageView(
                            icon: Icons.broken_image_outlined,
                            title: 'Couldn’t display this image',
                            message: 'The file may be damaged or in a format this phone can’t show.',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              DraggableScrollableSheet(
                initialChildSize: 0.3,
                minChildSize: _minSheet,
                maxChildSize: 0.9,
                snap: true,
                snapSizes: const [0.3],
                builder: (context, scroll) => _DetailsSheet(
                  scroll: scroll,
                  image: data.image,
                  reasons: widget.result.reasons,
                ),
              ),
            ],
          ),
        ),
      AsyncData() => SafeArea(
          child: MessageView(
            icon: Icons.image_not_supported_outlined,
            title: 'This photo is no longer available',
            message: 'It may have been deleted, moved, or access to it was removed. '
                'It will disappear from search the next time your photos are updated.',
            action: OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Back to results')),
          ),
        ),
      AsyncError() => SafeArea(
          child: ErrorView(
            title: 'Couldn’t open this photo',
            onRetry: () => ref.invalidate(viewerImageProvider(id)),
          ),
        ),
      _ => const Center(child: CircularProgressIndicator(semanticsLabel: 'Loading photo')),
    };
  }
}

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.scroll, required this.image, required this.reasons});

  final ScrollController scroll;
  final GalleryImage image;
  final List<MatchReason> reasons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final folder = image.relativePath?.replaceAll(RegExp(r'/+$'), '');
    return Material(
      color: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.xs, AppSpace.lg, AppSpace.xl),
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(bottom: AppSpace.xs),
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ),
          if (reasons.isNotEmpty) ...[
            const SectionHeader('Why this matched', padding: EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.sm)),
            MatchReasonsView(reasons: reasons),
          ],
          const SectionHeader('Details', padding: EdgeInsets.only(top: AppSpace.sm, bottom: AppSpace.xs)),
          _MetaRow(icon: Icons.event_outlined, label: 'Date', value: formatLongDateTime(image.createdAt)),
          _MetaRow(
            icon: image.kind == ImageKind.screenshot ? Icons.screenshot_outlined : Icons.photo_outlined,
            label: 'Type',
            value: kindLabel(image.kind),
          ),
          if (image.width > 0 && image.height > 0)
            _MetaRow(icon: Icons.aspect_ratio, label: 'Dimensions', value: '${image.width} × ${image.height}'),
          if (image.filename != null)
            _MetaRow(icon: Icons.insert_drive_file_outlined, label: 'File name', value: image.filename!),
          if (folder != null && folder.isNotEmpty)
            _MetaRow(icon: Icons.folder_outlined, label: 'Folder', value: folder),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  SelectableText(value, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
