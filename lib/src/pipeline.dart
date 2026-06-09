import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'features/feature.dart';
import 'source_edit.dart';

/// One feature skipped for a file because the file's effective language version
/// is below the feature's floor.
class SkippedFeature {
  final String featureId;
  final Version required;
  final Version effective;
  const SkippedFeature(this.featureId, this.required, this.effective);
}

/// Result of re-analyzing edited content in an in-memory overlay.
class VerifyResult {
  final bool ok;
  final int baselineErrors;
  final int newErrors;
  final String? note;
  const VerifyResult({
    required this.ok,
    required this.baselineErrors,
    required this.newErrors,
    this.note,
  });

  static const skipped = VerifyResult(
    ok: true,
    baselineErrors: 0,
    newErrors: 0,
    note: 'verify skipped',
  );
}

/// Per-file migration outcome.
class FileResult {
  final String path;
  final String originalContent;
  final String? newContent;
  final List<SourceEdit> applied;
  final List<SourceEdit> dropped;
  final List<SkippedFeature> skippedByVersion;
  final VerifyResult verify;

  const FileResult({
    required this.path,
    required this.originalContent,
    required this.newContent,
    required this.applied,
    required this.dropped,
    required this.skippedByVersion,
    required this.verify,
  });

  /// True when there are verified edits worth writing.
  bool get changed =>
      newContent != null && applied.isNotEmpty && verify.ok;
}

/// Resolves files, runs enabled features, merges and verifies their edits.
class Pipeline {
  final List<Feature> features;
  final bool verifyEnabled;

  Pipeline({required this.features, this.verifyEnabled = true});

  int _stamp = 1;

  Future<List<FileResult>> run(String packageRoot, List<String> files) async {
    final overlay = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
    final collection = AnalysisContextCollection(
      includedPaths: [p.normalize(p.absolute(packageRoot))],
      resourceProvider: overlay,
    );

    final results = <FileResult>[];
    for (final path in files) {
      final ctx = collection.contextFor(path);
      final resolved = await ctx.currentSession.getResolvedUnit(path);
      if (resolved is! ResolvedUnitResult) continue;

      final effective = resolved.libraryElement.languageVersion.effective;

      final edits = <SourceEdit>[];
      final skipped = <SkippedFeature>[];
      for (final feature in features) {
        if (effective < feature.minLanguageVersion) {
          skipped.add(SkippedFeature(
            feature.id,
            feature.minLanguageVersion,
            effective,
          ));
          continue;
        }
        edits.addAll(feature.collect(resolved));
      }

      if (edits.isEmpty) {
        results.add(FileResult(
          path: path,
          originalContent: resolved.content,
          newContent: null,
          applied: const [],
          dropped: const [],
          skippedByVersion: skipped,
          verify: VerifyResult.skipped,
        ));
        continue;
      }

      final merge = mergeEdits(edits);
      final newContent = applyEdits(resolved.content, merge.kept);

      VerifyResult verify;
      if (verifyEnabled) {
        verify = await _verify(
          overlay,
          ctx,
          path,
          baseline: resolved.diagnostics,
          newContent: newContent,
        );
      } else {
        verify = VerifyResult.skipped;
      }

      results.add(FileResult(
        path: path,
        originalContent: resolved.content,
        newContent: newContent,
        applied: merge.kept,
        dropped: merge.dropped,
        skippedByVersion: skipped,
        verify: verify,
      ));
    }
    return results;
  }

  /// Re-resolves [newContent] through the overlay and checks no new errors
  /// appear versus the [baseline]. Restores the overlay afterward so a dry-run
  /// leaves the on-disk view intact.
  Future<VerifyResult> _verify(
    OverlayResourceProvider overlay,
    AnalysisContext ctx,
    String path, {
    required List<Diagnostic> baseline,
    required String newContent,
  }) async {
    final baselineErrors = _errorCount(baseline);
    try {
      overlay.setOverlay(
        path,
        content: newContent,
        modificationStamp: _stamp++,
      );
      ctx.changeFile(path);
      await ctx.applyPendingFileChanges();
      final reResolved = await ctx.currentSession.getResolvedUnit(path);
      final newErrors = reResolved is ResolvedUnitResult
          ? _errorCount(reResolved.diagnostics)
          : baselineErrors + 1; // could not resolve -> treat as failure
      return VerifyResult(
        ok: newErrors <= baselineErrors,
        baselineErrors: baselineErrors,
        newErrors: newErrors,
        note: newErrors > baselineErrors
            ? 'edit introduced ${newErrors - baselineErrors} new error(s)'
            : null,
      );
    } finally {
      overlay.removeOverlay(path);
      ctx.changeFile(path);
      await ctx.applyPendingFileChanges();
    }
  }

  int _errorCount(List<Diagnostic> diagnostics) => diagnostics
      .where((d) => d.diagnosticCode.severity == DiagnosticSeverity.ERROR)
      .length;
}
