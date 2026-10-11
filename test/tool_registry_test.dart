/// Tests for the tool layer.
///
/// These exist because of a specific failure: seven tools returned
/// `{"status":"success"}` without doing anything, so the model told the user
/// their SMS had been sent when no message existed. Every test below is an
/// attempt to make that impossible to reintroduce.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/utils/json_extract.dart';
import 'package:localmind/data/tools/tool_registry.dart';
import 'package:localmind/domain/models/tool_result.dart';

void main() {
  final registry = ToolRegistry()..registerTools();

  group('ToolDefinition.schema', () {
    test('every registered tool produces parseable JSON', () {
      expect(registry.tools, isNotEmpty);
      for (final def in registry.tools.values) {
        // The old implementation built this string by interpolation, so any
        // description containing a quote produced invalid JSON. Decoding is
        // the only way to know it is well formed.
        final decoded = jsonDecode(def.schema);
        expect(decoded, isA<Map<String, dynamic>>(),
            reason: '${def.name} schema did not decode to an object');
      }
    });

    test('schema carries the expected shape', () {
      for (final def in registry.tools.values) {
        final decoded = jsonDecode(def.schema) as Map<String, dynamic>;
        expect(decoded['name'], def.name);
        expect(decoded['description'], isA<String>());

        final params = decoded['parameters'] as Map<String, dynamic>;
        expect(params['type'], 'object');
        expect(params['properties'], isA<Map<String, dynamic>>());
        expect(params['required'], isA<List<dynamic>>());
      }
    });

    test('required matches the declared list and never throws', () {
      final sms = registry.tools['send_sms']!;
      final decoded = jsonDecode(sms.schema) as Map<String, dynamic>;
      final params = decoded['parameters'] as Map<String, dynamic>;
      final required = (params['required'] as List).cast<String>();

      expect(required, containsAll(<String>['recipient', 'message']));
    });

    test('a description containing quotes still yields valid JSON', () {
      // Regression: the previous builder interpolated description text
      // directly, so a quote broke the whole payload.
      final def = ToolDefinition(
        name: 'quote_test',
        description: 'Says "hello" and \\ backslash',
        parameters: {
          'q': {'type': 'string', 'description': 'has a "quote" inside'},
        },
        required: const ['q'],
        implemented: false,
      );

      final decoded = jsonDecode(def.schema) as Map<String, dynamic>;
      expect(decoded['description'], 'Says "hello" and \\ backslash');
      final props =
          (decoded['parameters'] as Map<String, dynamic>)['properties']
              as Map<String, dynamic>;
      expect(props['q']['description'], 'has a "quote" inside');
    });

    test('the never-set "optional" key is gone', () {
      // The old code derived `required` from `!parameters[k]['optional']`, and
      // no tool ever set `optional`, so this was a null-check on null and threw.
      for (final def in registry.tools.values) {
        for (final entry in def.parameters.entries) {
          expect((entry.value as Map).containsKey('optional'), isFalse,
              reason: '${def.name}.${entry.key} still carries "optional"');
        }
      }
    });
  });

  group('ToolRegistry', () {
    test('registerTools populates the registry', () {
      // It was never called before, so the registry was permanently empty.
      expect(registry.tools.length, greaterThan(5));
    });

    test('unimplemented tools are hidden from the model', () {
      final offered = registry.toolsForModel.map((t) => t.name).toSet();

      // These have real implementations and must be offered.
      expect(offered, contains('get_location'));
      expect(offered, contains('analyze_image'));
      expect(offered, contains('web_search'));

      // These do nothing yet, so the model must not see them.
      expect(offered, isNot(contains('send_sms')));
      expect(offered, isNot(contains('add_contact')));
      expect(offered, isNot(contains('open_app')));

      expect(offered.length, registry.tools.values.where((t) => t.implemented).length);
    });

    test('no unimplemented tool can ever report success', () async {
      final unimplemented =
          registry.tools.values.where((t) => !t.implemented).toList();
      expect(unimplemented, isNotEmpty);

      for (final def in unimplemented) {
        final result = await registry.executeTool(
          toolName: def.name,
          params: const {},
        );
        expect(result.status, ToolStatus.unsupported,
            reason: '${def.name} must not claim success');
        expect(result.isSuccess, isFalse);
        expect(result.message, isNotEmpty,
            reason: '${def.name} must explain why it cannot run');
      }
    });

    test('an unknown tool fails rather than silently succeeding', () async {
      final result = await registry.executeTool(
        toolName: 'does_not_exist',
        params: const {},
      );
      expect(result.status, ToolStatus.failed);
      expect(result.isSuccess, isFalse);
    });

    test('isImplemented agrees with the registry', () {
      expect(registry.isImplemented('get_location'), isTrue);
      expect(registry.isImplemented('send_sms'), isFalse);
      expect(registry.isImplemented('nope'), isFalse);
    });
  });

  group('ToolResult', () {
    test('wire statuses are stable', () {
      expect(ToolResult.success('x').status.wire, 'success');
      expect(ToolResult.failed('x').status.wire, 'failed');
      expect(ToolResult.unsupported('x').status.wire, 'unsupported');
      expect(ToolResult.requiresPermission('x').status.wire,
          'requires_permission');
      expect(ToolResult.awaitingConfirmation('x').status.wire,
          'awaiting_confirmation');
      expect(ToolResult.requiresUserAction('x').status.wire,
          'requires_user_action');
    });

    test('only success counts as a completed action', () {
      expect(ToolResult.success('ok').isCompletedAction, isTrue);

      // Opening the SMS composer is not the same as sending a message.
      expect(ToolResult.requiresUserAction('composer opened').isCompletedAction,
          isFalse);
      expect(ToolResult.unsupported('nope').isCompletedAction, isFalse);
      expect(ToolResult.failed('boom').isCompletedAction, isFalse);
      expect(ToolResult.requiresPermission('need it').isCompletedAction, isFalse);
      expect(ToolResult.awaitingConfirmation('ask me').isCompletedAction, isFalse);
    });

    test('never reports success for a non-success status', () {
      final notSuccess = <ToolResult>[
        ToolResult.failed('a'),
        ToolResult.unsupported('b'),
        ToolResult.requiresPermission('c'),
        ToolResult.awaitingConfirmation('d'),
        ToolResult.requiresUserAction('e'),
      ];
      for (final r in notSuccess) {
        expect(r.isSuccess, isFalse);
      }
    });

    test('serialises to JSON the model can read', () {
      final decoded = jsonDecode(
        ToolResult.success('done', data: {'answer': 42}).toJson(),
      ) as Map<String, dynamic>;
      expect(decoded['status'], 'success');
      expect(decoded['message'], 'done');
      expect(decoded['answer'], 42);
    });
  });

  group('extractJsonObject', () {
    test('parses a bare object', () {
      final r = extractJsonObject('{"plan": []}');
      expect(r, isNotNull);
      expect(r!['plan'], isEmpty);
    });

    test('unwraps a fenced block', () {
      final r = extractJsonObject('```json\n{"plan": [1]}\n```');
      expect(r, isNotNull);
      expect(r!['plan'], [1]);
    });

    test('unwraps a fence with leading prose', () {
      final r = extractJsonObject(
        'Sure! Here is the plan:\n```json\n{"plan": ["a"]}\n```\nHope that helps.',
      );
      expect(r, isNotNull);
      expect(r!['plan'], ['a']);
    });

    test('finds an object inside surrounding prose', () {
      final r = extractJsonObject('The answer is {"plan": []} as requested');
      expect(r, isNotNull);
      expect(r!['plan'], isEmpty);
    });

    test('returns null for unparseable input rather than throwing', () {
      // Returning null is what lets the orchestrator fall back to answering the
      // question directly. Throwing here is what used to strand the agent.
      expect(extractJsonObject(''), isNull);
      expect(extractJsonObject('I cannot help with that.'), isNull);
      expect(extractJsonObject('{ not json at all '), isNull);
      expect(extractJsonObject('```json\n{ broken\n```'), isNull);
    });

    test('ignores a JSON array at the top level', () {
      expect(extractJsonObject('[1,2,3]'), isNull);
    });
  });
}
