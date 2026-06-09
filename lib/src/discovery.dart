import 'dart:io';

import 'package:path/path.dart' as p;

/// Locates the target package and enumerates the hand-written Dart files that
/// are eligible for migration, excluding everything generated.
class Discovery {
  /// Generated-file suffixes for this repo's toolchain (auto_route, build_runner,
  /// freezed, injectable, mocktail). These are never edited.
  static const generatedSuffixes = <String>[
    '.g.dart',
    '.freezed.dart',
    '.gr.dart',
    '.config.dart',
    '.mocks.dart',
    '.gen.dart',
  ];

  /// Absolute paths (normalized) of files explicitly excluded by content/convention,
  /// e.g. the design-tokens file emitted by `tool/ds_generator.dart`.
  static const generatedRelativePaths = <String>[
    'lib/app/app_design_tokens.dart',
  ];

  /// Walks up from [start] until it finds a directory containing `pubspec.yaml`.
  static String findPackageRoot(String start) {
    var dir = Directory(p.normalize(p.absolute(start)));
    // If start is a file, begin at its parent.
    if (FileSystemEntity.isFileSync(dir.path)) {
      dir = dir.parent;
    }
    while (true) {
      if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError('No pubspec.yaml found above $start');
      }
      dir = parent;
    }
  }

  /// Returns absolute, normalized paths of `.dart` files under [roots] that are
  /// not generated. [roots] may be files or directories.
  static List<String> dartFiles(String packageRoot, List<String> roots) {
    final out = <String>{};
    for (final root in roots) {
      final abs = p.normalize(p.absolute(root));
      final entity = FileSystemEntity.typeSync(abs);
      if (entity == FileSystemEntityType.file) {
        if (_isMigratable(packageRoot, abs)) out.add(abs);
      } else if (entity == FileSystemEntityType.directory) {
        for (final f in Directory(abs).listSync(recursive: true)) {
          if (f is File &&
              f.path.endsWith('.dart') &&
              _isMigratable(packageRoot, p.normalize(f.path))) {
            out.add(p.normalize(f.path));
          }
        }
      }
    }
    final list = out.toList()..sort();
    return list;
  }

  /// True if [absPath] is a hand-written Dart file we may edit.
  static bool _isMigratable(String packageRoot, String absPath) {
    if (!absPath.endsWith('.dart')) return false;
    final base = p.basename(absPath);
    for (final suffix in generatedSuffixes) {
      if (base.endsWith(suffix)) return false;
    }
    final rel = p.relative(absPath, from: packageRoot);
    for (final excluded in generatedRelativePaths) {
      if (p.equals(rel, excluded)) return false;
    }
    // Catch-all: respect the standard generated-code banner.
    final firstLines = _firstLines(absPath, 3);
    if (firstLines.contains('GENERATED CODE - DO NOT MODIFY BY HAND') ||
        firstLines.contains('dart format off') &&
            firstLines.contains('coverage:ignore-file')) {
      return false;
    }
    return true;
  }

  static String _firstLines(String path, int n) {
    try {
      final lines = File(path).readAsLinesSync();
      return lines.take(n).join('\n');
    } catch (_) {
      return '';
    }
  }
}
