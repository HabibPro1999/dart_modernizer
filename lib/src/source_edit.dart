/// A single, contiguous text replacement in one source file, plus the metadata
/// the reporter and merge step need.
///
/// Edits are computed against the *original* file content. They are applied in
/// reverse-offset order so earlier offsets stay valid as later text is spliced.
class SourceEdit {
  /// Offset of the first replaced code unit in the original source.
  final int offset;

  /// Number of original code units replaced (0 = pure insertion).
  final int length;

  /// Text spliced in place of `[offset, offset + length)`.
  final String replacement;

  /// Owning feature id, e.g. `dot-shorthands` — used for overlap priority and
  /// per-feature reporting.
  final String featureId;

  /// Higher wins when two edits overlap. See [mergeEdits].
  final int priority;

  /// 1-based line of [offset], for human-readable reports.
  final int line;

  /// One-line summary, e.g. `VideoMode.native -> .native`.
  final String description;

  const SourceEdit({
    required this.offset,
    required this.length,
    required this.replacement,
    required this.featureId,
    required this.priority,
    required this.line,
    required this.description,
  });

  int get end => offset + length;

  bool overlaps(SourceEdit other) =>
      offset < other.end && other.offset < end;
}

/// Outcome of reconciling all edits for one file.
class MergeResult {
  /// Non-overlapping edits, sorted by ascending offset, safe to apply.
  final List<SourceEdit> kept;

  /// Edits dropped because they collided with a higher-priority edit.
  final List<SourceEdit> dropped;

  const MergeResult(this.kept, this.dropped);
}

/// Sorts [edits] and drops any that overlap an already-kept edit.
///
/// On overlap the higher [SourceEdit.priority] wins; ties keep the earlier
/// offset. Applying overlapping edits is undefined, so we never do — we drop
/// and report instead.
MergeResult mergeEdits(List<SourceEdit> edits) {
  final sorted = [...edits]..sort((a, b) {
    final byOffset = a.offset.compareTo(b.offset);
    if (byOffset != 0) return byOffset;
    return b.priority.compareTo(a.priority); // higher priority first on ties
  });

  final kept = <SourceEdit>[];
  final dropped = <SourceEdit>[];
  for (final edit in sorted) {
    final clash = kept.isNotEmpty && kept.last.overlaps(edit);
    if (clash) {
      // kept.last was chosen first (higher priority or earlier); drop this one.
      dropped.add(edit);
    } else {
      kept.add(edit);
    }
  }
  return MergeResult(kept, dropped);
}

/// Applies non-overlapping [edits] to [source].
///
/// Edits are applied highest-offset first so each splice leaves lower offsets
/// untouched. Callers should pass the [MergeResult.kept] list.
String applyEdits(String source, List<SourceEdit> edits) {
  final ordered = [...edits]..sort((a, b) => b.offset.compareTo(a.offset));
  var result = source;
  for (final edit in ordered) {
    result = result.replaceRange(edit.offset, edit.end, edit.replacement);
  }
  return result;
}
