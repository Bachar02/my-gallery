import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models.dart';
import '../design/tokens.dart';
import 'format.dart';

/// Thumbnail request: image id plus the requested longest side in pixels.
typedef ThumbnailRequest = ({String id, int size});

/// Encoded thumbnail bytes (null when unavailable). The repository caches;
/// this provider is disposed when off-screen.
final thumbnailProvider = FutureProvider.autoDispose.family<Uint8List?, ThumbnailRequest>(
  (ref, req) => ref.watch(galleryRepositoryProvider).thumbnail(req.id, size: req.size),
  retry: (_, _) => null,
);

/// Size buckets keep the repository cache effective across tile sizes.
const thumbnailBuckets = [256, 384, 512, 768, 1024];

/// Longest-side size to request so that the image's *short* side covers a
/// square tile of [tilePx] physical pixels, rounded up to a bucket.
int thumbnailSizeFor({required double tilePx, required int width, required int height}) {
  final longSide = width > height ? width : height;
  final shortSide = width > height ? height : width;
  final ratio = (shortSide <= 0 || longSide <= 0) ? 1.0 : longSide / shortSide;
  final needed = (tilePx * ratio).ceil();
  for (final b in thumbnailBuckets) {
    if (b >= needed) return b;
  }
  return thumbnailBuckets.last;
}

/// Square-cropped thumbnail, sharp at the device's pixel density.
/// Screenshots are cropped from the top, where the title or chat header is.
class GalleryThumbnail extends ConsumerWidget {
  const GalleryThumbnail({super.key, required this.image});

  final GalleryImage image;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final side = constraints.biggest.shortestSide.isFinite ? constraints.biggest.shortestSide : 128.0;
      final size = thumbnailSizeFor(tilePx: side * dpr, width: image.width, height: image.height);
      final thumb = ref.watch(thumbnailProvider((id: image.id, size: size)));
      final unavailable = ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Center(child: Icon(Icons.image_not_supported_outlined, color: scheme.onSurfaceVariant)),
      );
      return switch (thumb) {
        AsyncData(value: final bytes?) => Image.memory(
            bytes,
            fit: BoxFit.cover,
            alignment: image.kind == ImageKind.screenshot ? Alignment.topCenter : Alignment.center,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => unavailable,
          ),
        AsyncData() || AsyncError() => unavailable,
        _ => ColoredBox(color: scheme.surfaceContainerHighest),
      };
    });
  }
}

/// One search result: thumbnail with the date (and type icon) beneath.
class ResultTile extends StatelessWidget {
  const ResultTile({super.key, required this.result, required this.onTap});

  final SearchResult result;
  final VoidCallback onTap;

  /// Height of the caption below the square thumbnail, honoring text scale.
  static double captionHeight(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium!;
    final scaled = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 12);
    return scaled * (style.height ?? 1.4) + AppSpace.xs * 2;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = result.image;
    final reason = result.reasons.isEmpty ? '' : ', ${result.reasons.first.description}';
    return Semantics(
      button: true,
      label: '${kindLabel(image.kind)} from ${formatShortDate(image.createdAt)}$reason',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: GalleryThumbnail(image: image),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xxs, vertical: AppSpace.xs),
              child: Row(
                children: [
                  if (image.kind == ImageKind.screenshot) ...[
                    Icon(Icons.screenshot_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: AppSpace.xxs),
                  ],
                  Expanded(
                    child: Text(
                      formatShortDate(image.createdAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
