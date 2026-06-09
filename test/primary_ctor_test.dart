import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_modernizer/src/features/primary_constructors.dart';
import 'package:dart_modernizer/src/source_edit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The feature targets language 3.13 (experimental), above the test toolchain,
// so the full pipeline cannot emit or verify here. We exercise `collect()`
// directly against valid pre-3.13 input and assert the rewritten text.
void main() {
  final root = p.absolute('test/fixtures/sample_app');
  late String output;
  late List<SourceEdit> edits;

  setUpAll(() async {
    final file = p.normalize(p.join(root, 'lib', 'primary_ctor_cases.dart'));
    final collection =
        AnalysisContextCollection(includedPaths: [p.normalize(root)]);
    final resolved = await collection
        .contextFor(file)
        .currentSession
        .getResolvedUnit(file) as ResolvedUnitResult;
    edits = PrimaryConstructorsFeature().collect(resolved);
    output = applyEdits(resolved.content, mergeEdits(edits).kept);
  });

  test('migrates only the two eligible data classes', () {
    // Point: const-insert + body-collapse (2). Box: body-collapse (1).
    expect(edits.length, 3, reason: edits.map((e) => e.description).join('\n'));
  });

  test('const data class hoists into a const primary constructor', () {
    expect(output, contains('class const Point(final int x, final int y);'));
  });

  test('non-const generic data class keeps its type parameters', () {
    expect(output, contains('class Box<T>(final T value);'));
  });

  test('leaves the negative cases untouched', () {
    expect(output, contains('class WithMethod {'));
    expect(output, contains('int doubled() => n * 2;'));
    expect(output, contains('class Mutable {'));
    expect(output, contains('class Named {'));
    expect(output, contains('class WithInit {'));
    expect(output, contains('class PlainParam {'));
  });

  test('produces no overlapping edits', () {
    expect(mergeEdits(edits).dropped, isEmpty);
  });
}
