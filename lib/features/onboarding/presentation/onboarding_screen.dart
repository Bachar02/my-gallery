import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/tokens.dart';
import '../../../core/widgets/content_width.dart';
import '../../../domain/models.dart';
import 'permission_controller.dart';

/// Value proposition, privacy explanation and the gallery permission request.
/// Shown by the app shell while access is denied or permanently denied.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, required this.permission});

  final GalleryPermission permission;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _asked = false;
  bool _busy = false;

  Future<void> _request() async {
    setState(() => _busy = true);
    try {
      await ref.read(galleryPermissionProvider.notifier).request();
    } catch (_) {
      _showSnack('Couldn’t show the permission dialog. Please try again.');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _asked = true;
        });
      }
    }
  }

  Future<void> _openSettings() async {
    try {
      await ref.read(galleryPermissionProvider.notifier).openAppSettings();
    } catch (_) {
      _showSnack('Couldn’t open Settings. Open it from your phone’s Settings app.');
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final permanentlyDenied = widget.permission == GalleryPermission.permanentlyDenied;
    final showDeniedNote = permanentlyDenied || _asked;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.xl, AppSpace.lg, AppSpace.lg),
          child: ContentWidth(
            maxWidth: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: Icon(Icons.image_search, size: 40, color: scheme.onPrimaryContainer),
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                Semantics(
                  header: true,
                  child: Text('Find any photo by describing it', style: theme.textTheme.headlineMedium),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  'Type what you remember — “the restaurant menu from last summer” or '
                  '“the screenshot with Jamie’s address” — and AI Gallery finds it.',
                  style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpace.lg),
                const _Point(
                  icon: Icons.chat_bubble_outline,
                  title: 'Just describe it',
                  body: 'Search by what’s in the picture, a time, or the type of image.',
                ),
                const _Point(
                  icon: Icons.text_fields,
                  title: 'Reads text in your images',
                  body: 'Names, addresses and codes are found when they appear as text, like in screenshots. '
                      'It doesn’t recognise faces or people.',
                ),
                const _Point(
                  icon: Icons.lock_outline,
                  title: 'Private by design',
                  body: 'Everything is processed on this phone. Nothing is uploaded, and the app has no '
                      'internet permission, so your photos can’t leave your device.',
                ),
                const SizedBox(height: AppSpace.md),
                if (showDeniedNote) ...[
                  _DeniedNote(permanentlyDenied: permanentlyDenied),
                  const SizedBox(height: AppSpace.md),
                ],
                SizedBox(
                  width: double.infinity,
                  child: permanentlyDenied
                      ? FilledButton.icon(
                          onPressed: _openSettings,
                          icon: const Icon(Icons.settings_outlined),
                          label: const Text('Open Settings'),
                        )
                      : FilledButton.icon(
                          onPressed: _busy ? null : _request,
                          icon: _busy
                              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.photo_library_outlined),
                          label: Text(_asked ? 'Try again' : 'Allow photo access'),
                        ),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  'You can allow all photos or only some, and change this anytime in Settings.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpace.xxs),
                Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeniedNote extends StatelessWidget {
  const _DeniedNote({required this.permanentlyDenied});
  final bool permanentlyDenied;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                permanentlyDenied
                    ? 'Photo access is turned off for AI Gallery. To search your photos, open Settings, '
                        'tap Permissions › Photos and videos, and choose Allow.'
                    : 'Photo access wasn’t allowed. AI Gallery can only search photos it’s allowed to see.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
