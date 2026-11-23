import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Static placeholder block shown while content loads. Deliberately not
/// animated: cheap to render and calm to look at.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height, this.radius = AppRadius.md});

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}
