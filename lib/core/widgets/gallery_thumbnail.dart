import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models.dart';
import '../design/tokens.dart';
import 'format.dart';

/// Encoded thumbnail bytes for an image id (null when unavailable).
/// The repository caches; this provider is disposed when off-screen.
final thumbnailProvider = FutureProvider.autoDispose.family<Uint8List?, String>(
  (ref, id) => ref.watch(galleryRepositoryProvider).thumbnail(id, size: 256),
  retry: (_, _) => null,
);

/// Square thumbnail with placeholder and graceful fallback.
class GalleryThumbnail extends ConsumerWidget {
  const GalleryThumbnail({super.key, required this.imageId});

  final String imageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = ref.watch(thumbnailProvider(imageId));
    final placeholder = ColoredBox(color: scheme.surfaceContainerHighest);
    final unavailable = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(child: Icon(Icons.image_not_supported_outlined, color: scheme.onSurfaceVariant)),
    );
    return switch (thumb) {
      AsyncData(value: final bytes?) => Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => unavailable,
        ),
      AsyncData() || AsyncError() => unavailable,
      _ => placeholder,
    };
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
                child: GalleryThumbnail(imageId: image.id),
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
