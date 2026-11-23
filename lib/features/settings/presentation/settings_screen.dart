import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/design/tokens.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/format.dart';
import '../../../core/widgets/indexing_status_card.dart';
import '../../../core/widgets/section_header.dart';
import '../../../domain/models.dart';
import '../../home/presentation/home_screen.dart' show handleStatusAction, manageLimitedSelection;
import '../../home/presentation/indexing_controller.dart';
import '../../home/presentation/recent_searches_controller.dart';
import '../../onboarding/presentation/permission_controller.dart';
import 'settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xxl),
        children: const [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PermissionSection(),
                _IndexingSection(),
                _StatsSection(),
                _PrivacySection(),
                _DataSection(),
                _AboutSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionSection extends ConsumerWidget {
  const _PermissionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permission = ref.watch(galleryPermissionProvider);
    final controller = ref.read(galleryPermissionProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);

    Future<void> guarded(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        messenger.showSnackBar(const SnackBar(content: Text('That didn’t work. Please try again.')));
      }
    }

    final (String status, String detail, IconData icon, Widget? action) = switch (permission.value) {
      GalleryPermission.granted => (
          'Full access',
          'AI Gallery can search all photos and screenshots on this phone.',
          Icons.check_circle_outline,
          null,
        ),
      GalleryPermission.limited => (
          'Selected photos only',
          'Only the photos you chose can be searched.',
          Icons.photo_library_outlined,
          Wrap(
            spacing: AppSpace.xs,
            children: [
              TextButton(onPressed: () => manageLimitedSelection(context, ref), child: const Text('Change selection')),
              TextButton(onPressed: () => guarded(controller.openAppSettings), child: const Text('Allow all photos')),
            ],
          ),
        ),
      GalleryPermission.denied => (
          'Not allowed',
          'AI Gallery can’t see your photos.',
          Icons.no_photography_outlined,
          TextButton(
            onPressed: () => guarded(() async {
              final r = await controller.request();
              if (r.canBrowse) unawaited(ref.read(indexingActionsProvider).autoStart());
            }),
            child: const Text('Allow access'),
          ),
        ),
      GalleryPermission.permanentlyDenied => (
          'Turned off',
          'Photo access is off in system settings.',
          Icons.no_photography_outlined,
          TextButton(onPressed: () => guarded(controller.openAppSettings), child: const Text('Open Settings')),
        ),
      null => (
          permission.hasError ? 'Couldn’t check' : 'Checking…',
          permission.hasError ? 'Tap retry to check photo access again.' : '',
          Icons.help_outline,
          permission.hasError
              ? TextButton(onPressed: () => ref.invalidate(galleryPermissionProvider), child: const Text('Retry'))
              : null,
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Photo access'),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: Icon(icon),
                  title: Text(status),
                  subtitle: detail.isEmpty ? null : Text(detail),
                ),
                if (action != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
                    child: Align(alignment: AlignmentDirectional.centerEnd, child: action),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _IndexingSection extends ConsumerWidget {
  const _IndexingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(indexingProgressProvider);
    final stats = ref.watch(indexStatsProvider).value;
    final deleted = ref.watch(indexingDisabledProvider).value ?? false;
    final value = progress.value;
    final running = value?.isRunning ?? false;
    final actions = ref.read(indexingActionsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Indexing'),
        if (value != null)
          IndexingStatusCard(
            view: IndexingStatusView.from(value, stats, indexDeleted: deleted),
            onAction: (a) => handleStatusAction(context, ref, a),
          )
        else if (progress.hasError)
          Card(
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('Couldn’t read indexing status'),
              trailing: TextButton(
                onPressed: () => ref.invalidate(indexingProgressProvider),
                child: const Text('Retry'),
              ),
            ),
          )
        else
          const IndexingStatusCardSkeleton(),
        const SizedBox(height: AppSpace.xs),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: OutlinedButton.icon(
            onPressed: running ? null : () => unawaited(actions.rebuild()),
            icon: const Icon(Icons.refresh),
            label: const Text('Re-scan now'),
          ),
        ),
      ],
    );
  }
}

class _StatsSection extends ConsumerWidget {
  const _StatsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(indexStatsProvider);
    final Widget body;
    if (stats.value case final s?) {
      body = Column(
        children: [
          _StatRow(icon: Icons.photo_library_outlined, label: 'Searchable images', value: formatCount(s.indexedImages)),
          _StatRow(icon: Icons.screenshot_outlined, label: 'Screenshots', value: formatCount(s.screenshots)),
          _StatRow(icon: Icons.text_fields, label: 'Images with text', value: formatCount(s.imagesWithText)),
          _StatRow(
            icon: Icons.visibility_outlined,
            label: 'Ready for visual search',
            value: formatCount(s.imagesWithEmbedding),
          ),
          _StatRow(icon: Icons.storage_outlined, label: 'Index size on this phone', value: formatBytes(s.databaseBytes)),
          if (s.lastIndexedAt != null)
            _StatRow(icon: Icons.update, label: 'Last updated', value: formatRelative(s.lastIndexedAt!)),
        ],
      );
    } else if (stats.hasError) {
      body = ListTile(
        leading: const Icon(Icons.error_outline),
        title: const Text('Couldn’t load statistics'),
        trailing: TextButton(onPressed: () => ref.invalidate(indexStatsProvider), child: const Text('Retry')),
      );
    } else {
      body = const Padding(
        padding: EdgeInsets.all(AppSpace.md),
        child: Center(child: CircularProgressIndicator(semanticsLabel: 'Loading statistics')),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Your index'),
        Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: AppSpace.xs), child: body)),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: ListTile(
          leading: Icon(icon),
          title: Text(label),
          trailing: Text(value, style: Theme.of(context).textTheme.titleSmall),
        ),
      );
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget item(IconData icon, String title, String body) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(body),
          isThreeLine: false,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Privacy'),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: Column(
              children: [
                item(Icons.phone_android, 'Processed on this phone',
                    'Text recognition and visual search run on your device.'),
                item(Icons.cloud_off_outlined, 'Nothing leaves your device',
                    'AI Gallery has no internet permission, so it can’t upload anything. No account, no analytics.'),
                item(Icons.inventory_2_outlined, 'What’s stored',
                    'Text found in your images, a compact numeric description of each image for visual search, '
                    'basic file details (date, size, type) and your recent searches. '
                    'The index doesn’t contain copies of your photos.'),
                item(Icons.folder_special_outlined, 'Where',
                    'In the app’s private storage on this phone. Deleting the index or uninstalling the app removes it.'),
                item(Icons.face_retouching_off_outlined, 'No face recognition',
                    'AI Gallery doesn’t identify people. A name is found only when it appears as text in an image.'),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.xs, left: AppSpace.xs),
          child: Text(
            'Your photos stay where they are. AI Gallery never edits or deletes them.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _DataSection extends ConsumerWidget {
  const _DataSection();

  Future<void> _clearRecent(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(recentSearchesProvider.notifier).clear();
      messenger.showSnackBar(const SnackBar(content: Text('Recent searches cleared')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Couldn’t clear recent searches. Please try again.')));
    }
  }

  Future<void> _deleteIndex(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('Delete local index?'),
        content: const Text(
          'This removes the text, visual search data and recent searches AI Gallery has stored. '
          'Your photos are not affected.\n\nSearch won’t find anything until your photos are prepared again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(deleteIndexProvider.notifier).deleteIndex();
    if (ok) {
      final actions = ref.read(indexingActionsProvider);
      messenger.showSnackBar(SnackBar(
        content: const Text('Local index deleted'),
        duration: const Duration(seconds: 8),
        // A SnackBar with an action persists by default (until dismissed),
        // which kept this one on screen across later routes.
        persist: false,
        action: SnackBarAction(label: 'Rebuild index', onPressed: () => unawaited(actions.rebuild())),
      ));
    } else {
      messenger.showSnackBar(const SnackBar(content: Text('Couldn’t delete the index. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deleting = ref.watch(deleteIndexProvider).isLoading;
    final error = Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Your data'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.history_toggle_off),
                title: const Text('Clear recent searches'),
                onTap: () => _clearRecent(context, ref),
              ),
              const Divider(indent: AppSpace.md, endIndent: AppSpace.md),
              ListTile(
                leading: deleting
                    ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.delete_outline, color: error),
                title: Text('Delete local index', style: TextStyle(color: error)),
                subtitle: const Text('Removes everything AI Gallery has stored. Photos are not affected.'),
                enabled: !deleting,
                onTap: () => _deleteIndex(context, ref),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('About'),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.image_search),
                  title: Text('AI Gallery'),
                  subtitle: Text('Version $appVersion · Works fully offline'),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Open-source licenses'),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'AI Gallery',
                    applicationVersion: appVersion,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}
