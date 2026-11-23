import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Centered message used for empty, missing and error states.
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.details,
    this.action,
    this.secondaryAction,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// Extra content below the message (e.g. a list of tips).
  final Widget? details;
  final Widget? action;
  final Widget? secondaryAction;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: isError ? scheme.errorContainer : scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.md),
                  child: Icon(
                    icon,
                    size: 32,
                    color: isError ? scheme.onErrorContainer : scheme.onSecondaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
              ),
              if (message != null) ...[
                const SizedBox(height: AppSpace.xs),
                Text(
                  message!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
              if (details != null) ...[const SizedBox(height: AppSpace.md), details!],
              if (action != null) ...[const SizedBox(height: AppSpace.lg), action!],
              if (secondaryAction != null) ...[const SizedBox(height: AppSpace.xs), secondaryAction!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Generic friendly error with a retry button.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.title,
    this.message = 'Please try again. If it keeps happening, restart the app.',
    this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => MessageView(
        icon: Icons.error_outline,
        isError: true,
        title: title,
        message: message,
        action: onRetry == null
            ? null
            : FilledButton.tonalIcon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
      );
}

/// A bulleted tip line used in empty states.
class TipLine extends StatelessWidget {
  const TipLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: AppSpace.xs),
            child: Icon(Icons.lightbulb_outline, size: 18, color: theme.colorScheme.primary),
          ),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
