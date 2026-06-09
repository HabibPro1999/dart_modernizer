import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_modernizer/src/features/private_named_params.dart';
import 'package:dart_modernizer/src/source_edit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The feature targets language 3.12, above the test toolchain, so the full
// pipeline (which version-gates) cannot emit here. We exercise `collect()`
// directly against valid pre-3.12 input and assert the rewritten text.
void main() {
  final root = p.absolute('test/fixtures/sample_app');
  late String output;
  late List<SourceEdit> edits;

  setUpAll(() async {
    final file = p.normalize(p.join(root, 'lib', 'private_named_cases.dart'));
    final collection =
        AnalysisContextCollection(includedPaths: [p.normalize(root)]);
    final resolved = await collection
        .contextFor(file)
        .currentSession
        .getResolvedUnit(file) as ResolvedUnitResult;
    edits = PrivateNamedParamsFeature().collect(resolved);
    output = applyEdits(resolved.content, mergeEdits(edits).kept);
  });

  test('rewrites only the bare-copy named params', () {
    // Point: two params + drop both initializers. Mixed: one param + drop one.
    expect(edits.length, 5, reason: edits.map((e) => e.description).join('\n'));
  });

  test('Point collapses to private named formals', () {
    expect(output, contains('Point({required this._x, required this._y});'));
    expect(output, isNot(contains(': _x = x')));
  });

  test('Mixed rewrites `a` but keeps the existing `this.b` field formal', () {
    expect(output, contains('Mixed({required this._a, required this.b});'));
  });

  test('leaves the negative cases untouched', () {
    expect(output, contains('Transformed({required int v}) : _v = v * 2;'));
    expect(output, contains('Renamed({required int count}) : _total = count;'));
    expect(output, contains('Positional(int z) : _z = z;'));
    expect(output, contains('_sq = n * n')); // UsedTwice unchanged
    expect(output, contains('UsedTwice({required int n})'));
  });

  test('produces no overlapping edits', () {
    expect(mergeEdits(edits).dropped, isEmpty);
  });
}
