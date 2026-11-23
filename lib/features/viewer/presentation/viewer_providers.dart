import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../domain/models.dart';

/// A displayable image: fresh metadata plus encoded bytes.
class ViewerImage {
  const ViewerImage(this.image, this.bytes);
  final GalleryImage image;
  final Uint8List bytes;
}

/// Loads an image for full-screen display. Resolves to null when the image
/// no longer exists or can no longer be read.
final viewerImageProvider = FutureProvider.autoDispose.family<ViewerImage?, String>(
  (ref, id) async {
    final repo = ref.watch(galleryRepositoryProvider);
    final image = await repo.getImage(id);
    if (image == null) return null;
    final bytes = await repo.displayImage(id);
    if (bytes == null) return null;
    return ViewerImage(image, bytes);
  },
  retry: (_, _) => null,
);
