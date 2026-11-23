import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// The app's primary search input: a pill-shaped field with a search icon and
/// a clear button.
///
/// With [readOnly] = true it acts as a large button (used on Home) that opens
/// the search screen via [onTap].
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.onSubmitted,
    this.onTap,
    this.readOnly = false,
    this.autofocus = false,
    this.hintText = 'Describe the photo you’re looking for',
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final bool readOnly;
  final bool autofocus;
  final String hintText;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  TextEditingController? _ownController;
  TextEditingController get _controller => widget.controller ?? (_ownController ??= TextEditingController());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(AppSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownController)?.removeListener(_onChanged);
      _controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _ownController?.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _controller.text.isNotEmpty;

    final field = TextField(
      controller: _controller,
      focusNode: widget.focusNode,
      readOnly: widget.readOnly,
      autofocus: widget.autofocus,
      onTap: widget.onTap,
      onSubmitted: widget.onSubmitted,
      textInputAction: TextInputAction.search,
      minLines: 1,
      maxLines: 1,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintMaxLines: 1,
        prefixIcon: Icon(Icons.search, color: scheme.primary),
        suffixIcon: hasText && !widget.readOnly
            ? IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _controller.clear();
                  widget.focusNode?.requestFocus();
                },
              )
            : null,
      ),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppLayout.minTouchTarget + 8),
      child: widget.readOnly
          ? Semantics(button: true, label: 'Search your photos', excludeSemantics: true, child: field)
          : Semantics(textField: true, label: 'Search your photos', child: field),
    );
  }
}
