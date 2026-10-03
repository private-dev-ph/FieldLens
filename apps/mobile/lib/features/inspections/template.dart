/// Field types supported by schema-driven inspection templates.
enum FieldType {
  boolean,
  passFailNa,
  singleChoice,
  multipleChoice,
  numeric,
  text,
  photo,
  qrSerial,
  signature,
}

/// One prompt and its validation rules in an [InspectionTemplate].
class TemplateItem {
  TemplateItem({
    required this.id,
    required this.label,
    required this.type,
    required this.required,
    List<String> options = const [],
    this.min,
    this.max,
  }) : options = List.unmodifiable(options) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Cannot be empty');
    }
    if (label.trim().isEmpty) {
      throw ArgumentError.value(label, 'label', 'Cannot be empty');
    }
    if (this.options.any((option) => option.trim().isEmpty) ||
        this.options.toSet().length != this.options.length) {
      throw ArgumentError.value(
        options,
        'options',
        'Must be unique and non-empty',
      );
    }

    final usesOptions =
        type == FieldType.singleChoice || type == FieldType.multipleChoice;
    if (usesOptions && this.options.isEmpty) {
      throw ArgumentError.value(
        options,
        'options',
        'Choice fields need options',
      );
    }
    if (!usesOptions && this.options.isNotEmpty) {
      throw ArgumentError.value(
        options,
        'options',
        'Only choice fields use options',
      );
    }

    if ((min != null && !min!.isFinite) || (max != null && !max!.isFinite)) {
      throw ArgumentError('Numeric bounds must be finite');
    }
    if (min != null && max != null && min! > max!) {
      throw ArgumentError('Numeric minimum cannot exceed maximum');
    }
    if ((min != null || max != null) && type != FieldType.numeric) {
      throw ArgumentError('Only numeric fields may define bounds');
    }
  }

  final String id;
  final String label;
  final FieldType type;
  final bool required;
  final List<String> options;
  final double? min;
  final double? max;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'type': type.name,
    'required': required,
    'options': options,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
  };

  factory TemplateItem.fromJson(Map<String, Object?> json) {
    _checkKeys(json, const {
      'id',
      'label',
      'type',
      'required',
      'options',
      'min',
      'max',
    }, 'template item');
    final rawType = _string(json, 'type');
    final type = FieldType.values.where((value) => value.name == rawType);
    if (type.isEmpty) throw FormatException('Unknown field type: $rawType');
    final rawOptions = json['options'] ?? const <Object?>[];
    if (rawOptions is! List || rawOptions.any((value) => value is! String)) {
      throw const FormatException('options must be a list of strings');
    }
    return TemplateItem(
      id: _string(json, 'id'),
      label: _string(json, 'label'),
      type: type.single,
      required: _bool(json, 'required'),
      options: rawOptions.cast<String>(),
      min: _optionalNumber(json, 'min'),
      max: _optionalNumber(json, 'max'),
    );
  }
}

/// A versioned, immutable, schema-driven inspection form.
class InspectionTemplate {
  InspectionTemplate({
    required this.id,
    required this.revision,
    required this.title,
    required List<TemplateItem> items,
  }) : items = List.unmodifiable(items) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Cannot be empty');
    }
    if (revision <= 0) {
      throw ArgumentError.value(revision, 'revision', 'Must be positive');
    }
    if (title.trim().isEmpty) {
      throw ArgumentError.value(title, 'title', 'Cannot be empty');
    }
    final ids = this.items.map((item) => item.id).toList();
    if (ids.toSet().length != ids.length) {
      throw ArgumentError('Template item IDs must be unique');
    }
  }

  final String id;
  final int revision;
  final String title;
  final List<TemplateItem> items;

  Map<String, Object?> toJson() => {
    'id': id,
    'revision': revision,
    'title': title,
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };

  factory InspectionTemplate.fromJson(Map<String, Object?> json) {
    _checkKeys(json, const {'id', 'revision', 'title', 'items'}, 'template');
    final rawRevision = json['revision'];
    if (rawRevision is! int) {
      throw const FormatException('revision must be an integer');
    }
    final rawItems = json['items'];
    if (rawItems is! List ||
        rawItems.any((value) => value is! Map<String, Object?>)) {
      throw const FormatException('items must be a list of template items');
    }
    return InspectionTemplate(
      id: _string(json, 'id'),
      revision: rawRevision,
      title: _string(json, 'title'),
      items: rawItems
          .cast<Map<String, Object?>>()
          .map(TemplateItem.fromJson)
          .toList(growable: false),
    );
  }

  /// Returns errors keyed by item ID (or by an unexpected answer key).
  Map<String, String> validateAnswers(Map<String, Object?> answers) {
    final errors = <String, String>{};
    final itemIds = items.map((item) => item.id).toSet();
    for (final answerId in answers.keys) {
      if (!itemIds.contains(answerId)) {
        errors[answerId] = 'Answer does not belong to this template';
      }
    }
    for (final item in items) {
      final error = validateAnswer(
        item,
        answers[item.id],
        enforceRequired: true,
      );
      if (error != null) errors[item.id] = error;
    }
    return Map.unmodifiable(errors);
  }
}

/// Returns a validation message, or null when [value] is valid.
String? validateAnswer(
  TemplateItem item,
  Object? value, {
  bool enforceRequired = true,
}) {
  String? missingAnswer() {
    return enforceRequired && item.required ? 'This answer is required' : null;
  }

  switch (item.type) {
    case FieldType.boolean:
      if (value == null) return missingAnswer();
      return value is bool ? null : 'Expected true or false';
    case FieldType.passFailNa:
      if (value == null || (value is String && value.trim().isEmpty)) {
        return missingAnswer();
      }
      return const {'pass', 'fail', 'na'}.contains(value)
          ? null
          : 'Expected pass, fail, or na';
    case FieldType.singleChoice:
      if (value == null || (value is String && value.trim().isEmpty)) {
        return missingAnswer();
      }
      return value is String && item.options.contains(value)
          ? null
          : 'Choose one of the available options';
    case FieldType.multipleChoice:
      if (value == null || (value is List && value.isEmpty)) {
        return missingAnswer();
      }
      if (value is! List || value.any((entry) => entry is! String)) {
        return 'Expected a list of choices';
      }
      final choices = value.cast<String>();
      if (choices.toSet().length != choices.length) {
        return 'Choices must not be repeated';
      }
      return choices.every(item.options.contains)
          ? null
          : 'Choose only available options';
    case FieldType.numeric:
      if (value == null) return missingAnswer();
      if (value is! num || !value.isFinite) {
        return 'Expected a finite number';
      }
      final number = value.toDouble();
      if (item.min != null && number < item.min!) {
        return 'Must be at least ${item.min}';
      }
      if (item.max != null && number > item.max!) {
        return 'Must be at most ${item.max}';
      }
      return null;
    case FieldType.text:
    case FieldType.qrSerial:
      if (value == null || (value is String && value.trim().isEmpty)) {
        return missingAnswer();
      }
      return value is String ? null : 'Expected text';
    case FieldType.photo:
      if (value == null || (value is List && value.isEmpty)) {
        return missingAnswer();
      }
      if (value is! List || value.any((entry) => entry is! String)) {
        return 'Expected attachment UUID references';
      }
      final ids = value.cast<String>();
      if (ids.toSet().length != ids.length) {
        return 'Attachment references must not be repeated';
      }
      return ids.every(_isUuid) ? null : 'Expected attachment UUID references';
    case FieldType.signature:
      if (value == null) return missingAnswer();
      return value is String && _isUuid(value)
          ? null
          : 'Expected a signature UUID reference';
  }
}

/// Offline demo schema shared by Factory Demo work orders.
InspectionTemplate factoryDemoTemplate() => InspectionTemplate(
  id: '10000000-0000-4000-8000-000000000003',
  revision: 1,
  title: 'Factory asset inspection',
  items: [
    TemplateItem(
      id: 'safety_check',
      label: 'Area is safe to inspect',
      type: FieldType.boolean,
      required: true,
    ),
    TemplateItem(
      id: 'corrosion',
      label: 'Corrosion level',
      type: FieldType.singleChoice,
      required: true,
      options: const ['none', 'minor', 'moderate', 'severe'],
    ),
    TemplateItem(
      id: 'temperature_c',
      label: 'Observed temperature (°C)',
      type: FieldType.numeric,
      required: false,
    ),
    TemplateItem(
      id: 'notes',
      label: 'Inspection notes',
      type: FieldType.text,
      required: false,
    ),
  ],
);

bool _isUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
).hasMatch(value);

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

double? _optionalNumber(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num || !value.isFinite) {
    throw FormatException('$key must be a finite number');
  }
  return value.toDouble();
}

void _checkKeys(
  Map<String, Object?> json,
  Set<String> allowed,
  String subject,
) {
  final unknown = json.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw FormatException('Unknown $subject keys: ${unknown.join(', ')}');
  }
}
