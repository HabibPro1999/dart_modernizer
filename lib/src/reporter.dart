import 'dart:io';

import 'package:path/path.dart' as p;

import 'pipeline.dart';

/// Renders pipeline results to the terminal: per-file diffs, dropped/overlap
/// edits, version-skip notices, and per-feature totals.
class Reporter {
  final String packageRoot;
  final bool showDiff;

  Reporter({required this.packageRoot, required this.showDiff});

  void report(List<FileResult> results) {
    final changed = results.where((r) => r.changed).toList();
    final blockedVerify =
        results.where((r) => r.applied.isNotEmpty && !r.verify.ok).toList();

    for (final r in changed) {
      stdout.writeln(_rel(r.path));
      for (final e in r.applied) {
        stdout.writeln('  ${e.line}: ${e.description}  [${e.featureId}]');
      }
      if (showDiff) _printDiff(r);
      stdout.writeln();
    }

    if (blockedVerify.isNotEmpty) {
      stdout.writeln('--- skipped (verify failed: edits would not compile) ---');
      for (final r in blockedVerify) {
        stdout.writeln('  ${_rel(r.path)}: ${r.verify.note}');
      }
      stdout.writeln();
    }

    final droppedAny =
        results.where((r) => r.dropped.isNotEmpty).toList();
    if (droppedAny.isNotEmpty) {
      stdout.writeln('--- dropped (overlapping edits) ---');
      for (final r in droppedAny) {
        for (final e in r.dropped) {
          stdout.writeln('  ${_rel(r.path)}:${e.line}: ${e.description} '
              '[${e.featureId}] dropped for higher-priority edit');
        }
      }
      stdout.writeln();
    }

    _printTotals(results, changed, blockedVerify);
  }

  void _printTotals(
    List<FileResult> all,
    List<FileResult> changed,
    List<FileResult> blockedVerify,
  ) {
    final perFeature = <String, int>{};
    for (final r in changed) {
      for (final e in r.applied) {
        perFeature[e.featureId] = (perFeature[e.featureId] ?? 0) + 1;
      }
    }
    stdout.writeln('=== summary ===');
    stdout.writeln('files scanned:  ${all.length}');
    stdout.writeln('files changed:  ${changed.length}');
    if (perFeature.isEmpty) {
      stdout.writeln('edits:          0');
    } else {
      perFeature.forEach((id, n) {
        stdout.writeln('  $id: $n edit(s)');
      });
    }
    if (blockedVerify.isNotEmpty) {
      stdout.writeln('verify-blocked: ${blockedVerify.length} file(s)');
    }
  }

  void _printDiff(FileResult r) {
    final tmpDir = Directory.systemTemp.createTempSync('dart_modernizer_');
    try {
      final a = File(p.join(tmpDir.path, 'a.dart'))
        ..writeAsStringSync(r.originalContent);
      final b = File(p.join(tmpDir.path, 'b.dart'))
        ..writeAsStringSync(r.newContent ?? r.originalContent);
      final res = Process.runSync(
        'git',
        ['--no-pager', 'diff', '--no-index', '--', a.path, b.path],
      );
      // git diff --no-index exits 1 when files differ; that is expected.
      final out = (res.stdout as String);
      final body = out.split('\n').skip(4).join('\n'); // drop temp-path headers
      stdout.writeln(body.trimRight());
    } finally {
      tmpDir.deleteSync(recursive: true);
    }
  }

  String _rel(String path) => p.relative(path, from: packageRoot);
}
