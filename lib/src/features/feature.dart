import 'package:analyzer/dart/analysis/results.dart';
import 'package:pub_semver/pub_semver.dart';

import '../source_edit.dart';

/// A single migration (one language feature). Each feature inspects a resolved
/// unit and returns the edits it wants to make; the pipeline merges, verifies,
/// and applies them.
abstract class Feature {
  /// Stable id used on the CLI (`--<id>`) and in reports.
  String get id;

  /// Human label for reports.
  String get displayName;

  /// Lowest language version that can compile this feature's output.
  Version get minLanguageVersion;

  /// Higher wins when edits from two features overlap the same source range.
  int get priority;

  /// Whether the feature is experimental (off by default, banner shown).
  bool get experimental => false;

  /// Collects candidate edits from a fully *resolved* unit.
  List<SourceEdit> collect(ResolvedUnitResult unit);
}
