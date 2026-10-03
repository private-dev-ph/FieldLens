import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fieldlens_mobile/features/inspections/template.dart';

void main() {
  group('InspectionTemplate schema', () {
    test('round trips through JSON and keeps collections immutable', () {
      final template = factoryDemoTemplate();
      final decoded =
          jsonDecode(jsonEncode(template.toJson())) as Map<String, Object?>;
      final restored = InspectionTemplate.fromJson(decoded);

      expect(restored.toJson(), template.toJson());
      expect(restored.id, '10000000-0000-4000-8000-000000000003');
      expect(
        () => restored.items.add(
          TemplateItem(
            id: 'extra',
            label: 'Extra',
            type: FieldType.text,
            required: false,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test(
      'rejects unknown types, malformed shapes, and invalid identifiers',
      () {
        final json = factoryDemoTemplate().toJson();
        final items = (json['items']! as List).cast<Map<String, Object?>>();
        final invalidType = Map<String, Object?>.from(json)
          ..['items'] = [
            {...items.first, 'type': 'liveCameraInference'},
          ];
        expect(
          () => InspectionTemplate.fromJson(invalidType),
          throwsFormatException,
        );

        final extraKey = Map<String, Object?>.from(json)..['unexpected'] = true;
        expect(
          () => InspectionTemplate.fromJson(extraKey),
          throwsFormatException,
        );

        expect(
          () => InspectionTemplate(
            id: 'template',
            revision: 0,
            title: 'Template',
            items: const [],
          ),
          throwsArgumentError,
        );
        expect(
          () => InspectionTemplate(
            id: 'template',
            revision: 1,
            title: 'Template',
            items: [
              _item('duplicate', FieldType.text),
              _item('duplicate', FieldType.text),
            ],
          ),
          throwsArgumentError,
        );
        expect(
          () => TemplateItem(
            id: '',
            label: 'Empty ID',
            type: FieldType.text,
            required: false,
          ),
          throwsArgumentError,
        );
        expect(
          () => TemplateItem(
            id: 'range',
            label: 'Range',
            type: FieldType.numeric,
            required: false,
            min: 4,
            max: 3,
          ),
          throwsArgumentError,
        );
        expect(
          () => TemplateItem(
            id: 'options',
            label: 'Choices',
            type: FieldType.singleChoice,
            required: false,
            options: const ['same', 'same'],
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('answer validation', () {
    test('accepts values for every supported field family', () {
      final items = [
        _item('boolean', FieldType.boolean),
        _item('pass_fail_na', FieldType.passFailNa),
        _choice('single', FieldType.singleChoice),
        _choice('multiple', FieldType.multipleChoice),
        TemplateItem(
          id: 'numeric',
          label: 'Numeric',
          type: FieldType.numeric,
          required: true,
          min: 0,
          max: 10,
        ),
        _item('text', FieldType.text),
        _item('qr', FieldType.qrSerial),
        _item('photo', FieldType.photo),
        _item('signature', FieldType.signature),
      ];
      final template = InspectionTemplate(
        id: 'template',
        revision: 1,
        title: 'Every field',
        items: items,
      );

      expect(
        template.validateAnswers({
          'boolean': false,
          'pass_fail_na': 'na',
          'single': 'one',
          'multiple': ['one', 'two'],
          'numeric': 0,
          'text': 'Checked',
          'qr': 'SERIAL-1',
          'photo': ['10000000-0000-4000-8000-000000000010'],
          'signature': '10000000-0000-4000-8000-000000000011',
        }),
        isEmpty,
      );
    });

    test(
      'accepts false and zero as real answers and checks numeric bounds',
      () {
        final template = InspectionTemplate(
          id: 'template',
          revision: 1,
          title: 'Values',
          items: [
            _item('boolean', FieldType.boolean),
            TemplateItem(
              id: 'number',
              label: 'Number',
              type: FieldType.numeric,
              required: true,
              min: 0,
              max: 10,
            ),
          ],
        );

        expect(
          template.validateAnswers({'boolean': false, 'number': 0}),
          isEmpty,
        );
        expect(
          template.validateAnswers({'boolean': true, 'number': -0.01}),
          contains('number'),
        );
        expect(
          template.validateAnswers({'boolean': true, 'number': 10.01}),
          contains('number'),
        );
        expect(
          validateAnswer(
            template.items.last,
            double.nan,
            enforceRequired: false,
          ),
          isNotNull,
        );
      },
    );

    test('only accepts empty values that match an unanswered field shape', () {
      final optionalBoolean = TemplateItem(
        id: 'boolean',
        label: 'Boolean',
        type: FieldType.boolean,
        required: false,
      );
      final optionalNumber = TemplateItem(
        id: 'number',
        label: 'Number',
        type: FieldType.numeric,
        required: false,
      );
      final optionalText = TemplateItem(
        id: 'text',
        label: 'Text',
        type: FieldType.text,
        required: false,
      );
      final optionalChoice = TemplateItem(
        id: 'choice',
        label: 'Choice',
        type: FieldType.singleChoice,
        required: false,
        options: const ['one'],
      );
      final optionalMulti = TemplateItem(
        id: 'multi',
        label: 'Multi',
        type: FieldType.multipleChoice,
        required: false,
        options: const ['one'],
      );
      final optionalPhoto = TemplateItem(
        id: 'photo',
        label: 'Photo',
        type: FieldType.photo,
        required: false,
      );

      expect(validateAnswer(optionalBoolean, ''), isNotNull);
      expect(validateAnswer(optionalNumber, []), isNotNull);
      expect(validateAnswer(optionalText, '  '), isNull);
      expect(validateAnswer(optionalChoice, ''), isNull);
      expect(validateAnswer(optionalMulti, []), isNull);
      expect(validateAnswer(optionalPhoto, []), isNull);
      expect(validateAnswer(optionalBoolean, null), isNull);
    });

    test('requires answers and rejects malformed or extraneous values', () {
      final template = factoryDemoTemplate();
      final errors = template.validateAnswers({
        'safety_check': null,
        'corrosion': 'unknown',
        'temperature_c': 'hot',
        'unrecognized': 'value',
      });

      expect(
        errors.keys,
        containsAll([
          'safety_check',
          'corrosion',
          'temperature_c',
          'unrecognized',
        ]),
      );
      expect(
        template.validateAnswers({'safety_check': false, 'corrosion': 'none'}),
        isEmpty,
      );
      expect(
        template.validateAnswers({
          'safety_check': false,
          'corrosion': 'none',
          'notes': '  ',
        }),
        isEmpty,
      );
    });

    test(
      'enforces pass/fail values, unique multi-choice values, and UUID evidence refs',
      () {
        final passFail = _item('result', FieldType.passFailNa);
        expect(validateAnswer(passFail, 'fail'), isNull);
        expect(validateAnswer(passFail, 'unknown'), isNotNull);

        final multi = _choice('multi', FieldType.multipleChoice);
        expect(validateAnswer(multi, ['one', 'one']), isNotNull);
        expect(validateAnswer(multi, ['other']), isNotNull);

        expect(
          validateAnswer(_item('photo', FieldType.photo), ['not-a-uuid']),
          isNotNull,
        );
        expect(
          validateAnswer(_item('photo', FieldType.photo), [
            '10000000-0000-4000-8000-000000000010',
            '10000000-0000-4000-8000-000000000010',
          ]),
          isNotNull,
        );
        expect(
          validateAnswer(
            _item('signature', FieldType.signature),
            '10000000-0000-4000-8000-000000000012',
          ),
          isNull,
        );
      },
    );
  });
}

TemplateItem _item(String id, FieldType type) =>
    TemplateItem(id: id, label: id, type: type, required: true);

TemplateItem _choice(String id, FieldType type) => TemplateItem(
  id: id,
  label: id,
  type: type,
  required: true,
  options: const ['one', 'two'],
);
