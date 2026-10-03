import 'dart:convert';

/// Minimal structured logger that writes one JSON event per line.
///
/// Callers should pass identifiers and diagnostic context only, never secrets,
/// tokens, or inspection evidence.
class StructuredLog {
  const StructuredLog._();

  static void info(String event, {Map<String, Object?> fields = const {}}) =>
      _write('info', event, fields);

  static void warning(String event, {Map<String, Object?> fields = const {}}) =>
      _write('warning', event, fields);

  static void error(
    String event, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> fields = const {},
  }) {
    _write('error', event, {
      ...fields,
      // Exception messages can contain answer values or credentials. Record
      // the category and stack without copying those values into diagnostics.
      if (error != null) 'errorType': error.runtimeType.toString(),
      if (stackTrace != null) 'stackTrace': stackTrace.toString(),
    });
  }

  static void _write(String level, String event, Map<String, Object?> fields) {
    // ignore: avoid_print
    print(
      jsonEncode({
        ...fields,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'level': level,
        'event': event,
      }),
    );
  }
}
