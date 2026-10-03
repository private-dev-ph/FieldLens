import 'package:fieldlens_mobile/core/providers.dart';
import 'package:fieldlens_mobile/core/structured_log.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_repository.dart';
import 'package:fieldlens_mobile/features/inspections/template.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final inspectionRepositoryProvider = Provider<InspectionRepository>((ref) {
  return InspectionRepository(ref.watch(appDatabaseProvider));
});

final inspectionDraftProvider =
    StreamProvider.family<InspectionDraftView, String>((ref, draftId) {
      return ref.watch(inspectionRepositoryProvider).watchDraft(draftId);
    });

class InspectionScreen extends ConsumerStatefulWidget {
  const InspectionScreen({required this.draftId, super.key});

  final String draftId;

  @override
  ConsumerState<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends ConsumerState<InspectionScreen> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};
  final Map<String, Future<void>> _saveTails = {};
  final Map<String, int> _saveVersions = {};
  final Map<String, Object?> _expectedAnswers = {};
  final Set<String> _hasExpectedAnswer = {};
  final Set<String> _failedSaveFields = {};
  final Map<String, Object?> _failedValues = {};
  final Map<String, String> _inputErrors = {};
  final Map<String, String> _reviewErrors = {};
  final Map<String, _SaveState> _saveStates = {};
  Map<String, Object?> _latestAnswers = const {};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(inspectionDraftProvider(widget.draftId));
    return PopScope<Object?>(
      canPop: !_hasPendingSaves,
      child: Scaffold(
        appBar: AppBar(title: const Text('Inspection draft')),
        body: SafeArea(
          child: draft.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => _DraftLoadError(
              message: error.toString(),
              onRetry: () =>
                  ref.invalidate(inspectionDraftProvider(widget.draftId)),
            ),
            data: (view) {
              _latestAnswers = view.answers;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  Text(
                    view.template.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Answers are stored on this device as you work.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  for (final item in view.template.items) ...[
                    _itemCard(context, item, view.answers[item.id]),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const ValueKey('review-inspection-draft'),
                    onPressed: _hasPendingSaves
                        ? null
                        : () => _review(view.template, view.answers),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Review draft'),
                  ),
                  if (_reviewErrors.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Review ${_reviewErrors.length} answer${_reviewErrors.length == 1 ? '' : 's'} before this draft is complete.',
                      key: const ValueKey('draft-review-summary'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ] else if (_hasPendingSaves && _reviewWasCompleted) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Saving answers before the draft can be reviewed.',
                      key: ValueKey('draft-review-saving'),
                    ),
                  ] else if (_reviewWasCompleted &&
                      (_inputErrors.isNotEmpty ||
                          _failedSaveFields.isNotEmpty)) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Resolve the highlighted answers before reviewing again.',
                      key: ValueKey('draft-review-unresolved'),
                    ),
                  ] else if (_reviewWasCompleted) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'All current answers are valid. The draft remains saved locally.',
                      key: ValueKey('draft-review-valid'),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  bool _reviewWasCompleted = false;
  bool get _hasPendingSaves =>
      _saveStates.values.any((state) => state == _SaveState.saving);

  Widget _itemCard(BuildContext context, TemplateItem item, Object? answer) {
    _synchronizeController(item.id, answer);
    final validationMessage = _inputErrors[item.id] ?? _reviewErrors[item.id];
    return Card(
      key: ValueKey('inspection-item-${item.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    item.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (item.required)
                  Text(
                    'Required',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _fieldControl(context, item, answer),
            if (validationMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                validationMessage,
                key: ValueKey('inspection-error-${item.id}'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_saveStates[item.id] case final state?) ...[
              const SizedBox(height: 8),
              _saveStatus(context, item, state),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fieldControl(
    BuildContext context,
    TemplateItem item,
    Object? answer,
  ) {
    final currentAnswer = _answerFor(item.id, answer);
    switch (item.type) {
      case FieldType.boolean:
        final value = currentAnswer is bool ? currentAnswer : null;
        return SegmentedButton<bool>(
          key: ValueKey('field-${item.id}'),
          emptySelectionAllowed: true,
          segments: const [
            ButtonSegment(value: true, label: Text('Yes')),
            ButtonSegment(value: false, label: Text('No')),
          ],
          selected: value == null ? const {} : {value},
          onSelectionChanged: (selection) =>
              _saveField(item, selection.isEmpty ? null : selection.first),
        );
      case FieldType.passFailNa:
        final value = currentAnswer is String ? currentAnswer : null;
        return SegmentedButton<String>(
          key: ValueKey('field-${item.id}'),
          emptySelectionAllowed: true,
          segments: const [
            ButtonSegment(value: 'pass', label: Text('Pass')),
            ButtonSegment(value: 'fail', label: Text('Fail')),
            ButtonSegment(value: 'na', label: Text('N/A')),
          ],
          selected: value == null ? const {} : {value},
          onSelectionChanged: (selection) =>
              _saveField(item, selection.isEmpty ? null : selection.first),
        );
      case FieldType.singleChoice:
        final value =
            currentAnswer is String && item.options.contains(currentAnswer)
            ? currentAnswer
            : null;
        return DropdownButtonFormField<String>(
          key: ValueKey('field-${item.id}'),
          initialValue: value,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [
            for (final option in item.options)
              DropdownMenuItem(
                value: option,
                child: Text(_choiceLabel(option)),
              ),
          ],
          onChanged: (choice) => _saveField(item, choice),
        );
      case FieldType.multipleChoice:
        final selected = _stringValues(currentAnswer).toSet();
        return Column(
          children: [
            for (final option in item.options)
              CheckboxListTile(
                key: ValueKey('field-${item.id}-$option'),
                contentPadding: EdgeInsets.zero,
                title: Text(_choiceLabel(option)),
                value: selected.contains(option),
                onChanged: (checked) {
                  final next = {...selected};
                  if (checked ?? false) {
                    next.add(option);
                  } else {
                    next.remove(option);
                  }
                  _saveField(item, next.toList()..sort());
                },
              ),
          ],
        );
      case FieldType.numeric:
        return TextField(
          key: ValueKey('field-${item.id}'),
          controller: _controllerFor(item, answer),
          focusNode: _focusNodeFor(item.id),
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Enter a finite number',
          ),
          onChanged: (raw) {
            if (raw.trim().isEmpty) {
              _inputErrors.remove(item.id);
              _saveField(item, null);
              return;
            }
            final value = double.tryParse(raw.trim());
            if (value == null || !value.isFinite) {
              setState(() => _inputErrors[item.id] = 'Enter a finite number.');
              return;
            }
            final error = validateAnswer(item, value, enforceRequired: false);
            if (error != null) {
              setState(() => _inputErrors[item.id] = error);
              return;
            }
            setState(() => _inputErrors.remove(item.id));
            _saveField(item, value);
          },
        );
      case FieldType.text:
        return TextField(
          key: ValueKey('field-${item.id}'),
          controller: _controllerFor(item, answer),
          focusNode: _focusNodeFor(item.id),
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Enter inspection notes',
          ),
          onChanged: (value) => _saveText(item, value),
        );
      case FieldType.qrSerial:
        return TextField(
          key: ValueKey('field-${item.id}'),
          controller: _controllerFor(item, answer),
          focusNode: _focusNodeFor(item.id),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Serial or QR value',
            hintText: 'Enter a serial number or QR payload',
          ),
          onChanged: (value) => _saveText(item, value),
        );
      case FieldType.photo:
        final count = _stringValues(answer).length;
        return _EvidencePlaceholder(
          icon: Icons.photo_camera_outlined,
          message: count == 0
              ? 'Photo capture will be available in the evidence step.'
              : '$count photo ${count == 1 ? 'attachment' : 'attachments'} recorded',
        );
      case FieldType.signature:
        final hasSignature = answer is String && answer.isNotEmpty;
        return _EvidencePlaceholder(
          icon: Icons.draw_outlined,
          message: hasSignature
              ? 'Signature evidence is attached.'
              : 'Signature capture will be available in the evidence step.',
        );
    }
  }

  TextEditingController _controllerFor(TemplateItem item, Object? answer) {
    return _controllers.putIfAbsent(
      item.id,
      () => TextEditingController(text: _displayText(answer)),
    );
  }

  FocusNode _focusNodeFor(String itemId) {
    return _focusNodes.putIfAbsent(itemId, () {
      final focusNode = FocusNode();
      focusNode.addListener(() {
        if (!focusNode.hasFocus && mounted) {
          setState(
            () => _synchronizeController(itemId, _latestAnswers[itemId]),
          );
        }
      });
      return focusNode;
    });
  }

  void _synchronizeController(String itemId, Object? answer) {
    final expected = _expectedAnswers[itemId];
    if (_hasExpectedAnswer.contains(itemId) &&
        _answersEqual(answer, expected)) {
      _hasExpectedAnswer.remove(itemId);
      _expectedAnswers.remove(itemId);
    }
    final controller = _controllers[itemId];
    final focusNode = _focusNodes[itemId];
    if (controller == null ||
        focusNode?.hasFocus == true ||
        _hasExpectedAnswer.contains(itemId) ||
        _failedSaveFields.contains(itemId) ||
        _inputErrors.containsKey(itemId)) {
      return;
    }
    final nextText = _displayText(answer);
    if (controller.text != nextText) controller.text = nextText;
  }

  Object? _answerFor(String itemId, Object? persistedAnswer) =>
      _hasExpectedAnswer.contains(itemId)
      ? _expectedAnswers[itemId]
      : persistedAnswer;

  void _saveText(TemplateItem item, String value) {
    final error = validateAnswer(item, value, enforceRequired: false);
    if (error != null) {
      setState(() => _inputErrors[item.id] = error);
      return;
    }
    setState(() {
      _inputErrors.remove(item.id);
      _reviewErrors.remove(item.id);
      _failedSaveFields.remove(item.id);
    });
    _saveField(item, value);
  }

  void _saveField(TemplateItem item, Object? value) {
    final error = validateAnswer(item, value, enforceRequired: false);
    if (error != null) {
      setState(() => _inputErrors[item.id] = error);
      return;
    }

    setState(() {
      _reviewWasCompleted = false;
      _inputErrors.remove(item.id);
      _reviewErrors.remove(item.id);
      _failedSaveFields.remove(item.id);
      _saveStates[item.id] = _SaveState.saving;
      _expectedAnswers[item.id] = value;
      _hasExpectedAnswer.add(item.id);
    });

    final repository = ref.read(inspectionRepositoryProvider);
    final version = (_saveVersions[item.id] ?? 0) + 1;
    _saveVersions[item.id] = version;
    final previous = _saveTails[item.id] ?? Future<void>.value();
    final next = previous
        .catchError((Object _) {})
        .then((_) => repository.saveAnswer(widget.draftId, item.id, value));
    _saveTails[item.id] = next;
    next.then(
      (_) {
        if (!mounted || _saveVersions[item.id] != version) return;
        setState(() {
          _saveStates[item.id] = _SaveState.saved;
          _failedSaveFields.remove(item.id);
          _failedValues.remove(item.id);
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        StructuredLog.error(
          'inspection_answer_save_failed',
          error: error,
          stackTrace: stackTrace,
          fields: {'draftId': widget.draftId, 'itemId': item.id},
        );
        if (!mounted || _saveVersions[item.id] != version) return;
        setState(() {
          _failedSaveFields.add(item.id);
          _failedValues[item.id] = value;
          _hasExpectedAnswer.remove(item.id);
          _expectedAnswers.remove(item.id);
          _saveStates[item.id] = _SaveState.error;
        });
      },
    );
  }

  void _review(InspectionTemplate template, Map<String, Object?> answers) {
    setState(() {
      _reviewWasCompleted = true;
      _reviewErrors
        ..clear()
        ..addAll(template.validateAnswers({...answers, ..._expectedAnswers}))
        ..addAll(_inputErrors)
        ..addEntries(
          _failedSaveFields.map(
            (itemId) =>
                MapEntry(itemId, 'This answer could not be saved. Retry it.'),
          ),
        );
    });
  }

  Widget _saveStatus(
    BuildContext context,
    TemplateItem item,
    _SaveState state,
  ) {
    final (label, icon, color) = switch (state) {
      _SaveState.saving => (
        'Saving locally…',
        Icons.hourglass_top,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      _SaveState.saved => (
        'Saved locally',
        Icons.check_circle_outline,
        Theme.of(context).colorScheme.primary,
      ),
      _SaveState.error => (
        'Could not save locally',
        Icons.error_outline,
        Theme.of(context).colorScheme.error,
      ),
    };
    return Row(
      key: ValueKey('save-state-${item.id}'),
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
        if (state == _SaveState.error) ...[
          const Spacer(),
          TextButton(
            onPressed: () => _saveField(item, _failedValues[item.id]),
            child: const Text('Retry save'),
          ),
        ],
      ],
    );
  }
}

enum _SaveState { saving, saved, error }

class _EvidencePlaceholder extends StatelessWidget {
  const _EvidencePlaceholder({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class _DraftLoadError extends StatelessWidget {
  const _DraftLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(
              'Could not load inspection draft',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

List<String> _stringValues(Object? value) {
  if (value is! List || value.any((entry) => entry is! String)) return const [];
  return value.cast<String>();
}

String _displayText(Object? value) {
  if (value == null) return '';
  if (value is num) return '$value';
  if (value is String) return value;
  return '';
}

String _choiceLabel(String value) => value
    .split('_')
    .map(
      (word) =>
          word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}',
    )
    .join(' ');

bool _answersEqual(Object? left, Object? right) {
  if (left is num && right is num) return left == right;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_answersEqual(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
