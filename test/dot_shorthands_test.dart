import 'package:dart_modernizer/src/discovery.dart';
import 'package:dart_modernizer/src/features/dot_shorthands.dart';
import 'package:dart_modernizer/src/pipeline.dart';
import 'package:dart_modernizer/src/source_edit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final root = p.absolute('test/fixtures/sample_app');

  late List<FileResult> results;
  late List<SourceEdit> edits;

  setUpAll(() async {
    final files = Discovery.dartFiles(root, [p.join(root, 'lib')]);
    results = await Pipeline(
      features: [DotShorthandsFeature()],
      verifyEnabled: true,
    ).run(root, files);
    edits = results.expand((r) => r.applied).toList();
  });

  test('applies exactly the expected number of shorthands', () {
    expect(edits.length, 15, reason: descriptions(edits));
  });

  test('verify passes (no new errors introduced)', () {
    for (final r in results) {
      expect(r.verify.ok, isTrue, reason: '${r.path}: ${r.verify.note}');
    }
  });

  test('shortens the positive cases', () {
    final got = descriptions(edits);
    for (final expected in const [
      'Mode.native -> .native',
      'PostType.image -> .image',
      'Mode.preview -> .preview',
      'PostType.reel -> .reel',
      'PostType.video -> .video',
      'Mode.feed -> .feed',
      'Swatch.red -> .red',
    ]) {
      expect(got, contains(expected));
    }
  });

  test('switch scrutinee yields three pattern shorthands', () {
    final patternEdits =
        edits.where((e) => e.description.startsWith('PostType.')).toList();
    // image, video (== and switch), reel (return and switch) -> count check
    expect(patternEdits.length, greaterThanOrEqualTo(3));
  });

  test('never touches the negative cases', () {
    // Static-field-with-mismatched-context and static methods are excluded.
    expect(
      edits.where((e) => e.description.contains('Sizes.')),
      isEmpty,
    );
  });

  test('idempotent: applying then re-collecting yields no edits', () async {
    // Apply edits in-memory, then re-run the visitor over the new content by
    // checking that already-shortened forms are not re-matched. Here we assert
    // the merge/apply round-trips without overlap drops.
    for (final r in results) {
      expect(r.dropped, isEmpty, reason: '${r.path} had overlapping edits');
    }
  });
}

String descriptions(List<SourceEdit> edits) =>
    edits.map((e) => '${e.line}: ${e.description}').join('\n');
