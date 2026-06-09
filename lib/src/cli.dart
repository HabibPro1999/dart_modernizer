import 'dart:io';

import 'package:args/args.dart';

import 'discovery.dart';
import 'features/dot_shorthands.dart';
import 'features/feature.dart';
import 'features/primary_constructors.dart';
import 'features/private_named_params.dart';
import 'pipeline.dart';
import 'reporter.dart';
import 'version_gate.dart';

/// All features the tool knows about. Adding one here makes its `--<id>` flag
/// appear automatically.
List<Feature> _registry() => [
      DotShorthandsFeature(), // language >=3.10 (stable)
      PrivateNamedParamsFeature(), // language >=3.12 (stable)
      PrimaryConstructorsFeature(), // language >=3.13 (experimental)
    ];

/// Entry point. Returns the process exit code.
Future<int> run(List<String> argv) async {
  final registry = _registry();
  final parser = _buildParser(registry);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    return 64;
  }

  if (args['help'] as bool) {
    stdout.writeln('dart_modernizer — migrate this codebase to modern Dart.\n');
    stdout.writeln('Usage: dart_modernizer [paths...] [flags]\n');
    stdout.writeln(parser.usage);
    return 0;
  }

  final paths = args.rest.isEmpty ? ['lib'] : args.rest;
  final String packageRoot;
  try {
    packageRoot = Discovery.findPackageRoot(paths.first);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    return 66;
  }
  final sdk = SdkContext.load(packageRoot);

  final requested =
      registry.where((f) => args[f.id] as bool).toList();

  if (requested.isEmpty) {
    _printGateStatus(registry, sdk);
    return 0;
  }

  // Gate each requested feature on the SDK reality + experiment opt-in.
  final experiments = (args['enable-experiment'] as List<String>).toSet();
  final enabled = <Feature>[];
  for (final f in requested) {
    final gate = sdk.gateFor(f.minLanguageVersion);
    if (!gate.usable) {
      stderr.writeln('⚠ ${f.displayName} (--${f.id}) is BLOCKED: '
          '${gate.blockedReason()}. No edits will be produced.');
      continue;
    }
    if (f.experimental && !experiments.contains(f.id)) {
      stderr.writeln('⚠ ${f.displayName} (--${f.id}) is experimental; '
          're-run with --enable-experiment=${f.id} to use it.');
      continue;
    }
    if (f.experimental) {
      stderr.writeln('⚠ ${f.displayName} output compiles only under '
          '--enable-experiment=${f.id} and is non-production.');
    }
    enabled.add(f);
  }
  if (enabled.isEmpty) {
    stderr.writeln('No usable features enabled. Aborting.');
    return 1;
  }

  final apply = args['apply'] as bool;
  final force = args['force'] as bool;
  if (apply && !force && _isDirtyGitTree(packageRoot)) {
    stderr.writeln('Refusing to --apply on a dirty git tree '
        '(commit/stash first, or pass --force).');
    return 1;
  }

  final files = Discovery.dartFiles(packageRoot, paths);
  stdout.writeln('Scanning ${files.length} file(s) under '
      '${paths.join(", ")} '
      '[${enabled.map((f) => f.id).join(", ")}]'
      '${apply ? " — APPLY" : " — dry-run"}\n');

  final pipeline = Pipeline(
    features: enabled,
    verifyEnabled: args['verify'] as bool,
  );
  final results = await pipeline.run(packageRoot, files);

  Reporter(packageRoot: packageRoot, showDiff: args['diff'] as bool)
      .report(results);

  if (apply) {
    var written = 0;
    for (final r in results) {
      if (r.changed) {
        File(r.path).writeAsStringSync(r.newContent!);
        written++;
      }
    }
    stdout.writeln('\nApplied edits to $written file(s). '
        'Run `dart analyze` / `dart format` to confirm.');
  } else {
    stdout.writeln('\nDry-run only. Re-run with --apply to write changes.');
  }
  return 0;
}

ArgParser _buildParser(List<Feature> registry) {
  final parser = ArgParser();
  for (final f in registry) {
    parser.addFlag(
      f.id,
      defaultsTo: false,
      help: 'Enable ${f.displayName} (needs language >=${f.minLanguageVersion}'
          '${f.experimental ? ", experimental" : ""}).',
    );
  }
  parser
    ..addFlag('apply',
        negatable: false, help: 'Write changes (default: dry-run).')
    ..addFlag('diff', defaultsTo: true, help: 'Show a unified diff per file.')
    ..addFlag('verify',
        defaultsTo: true,
        help: 'Re-analyze each edited file; drop edits that add errors.')
    ..addFlag('force',
        negatable: false, help: 'Allow --apply on a dirty git tree.')
    ..addMultiOption('enable-experiment',
        help: 'Opt into an experimental feature, e.g. primary-constructors.')
    ..addFlag('help', abbr: 'h', negatable: false);
  return parser;
}

void _printGateStatus(List<Feature> registry, SdkContext sdk) {
  stdout.writeln('No feature selected. SDK status '
      '(package floor ${sdk.packageFloor}, installed ${sdk.installed}):\n');
  for (final f in registry) {
    final gate = sdk.gateFor(f.minLanguageVersion);
    final status = gate.usable ? 'USABLE' : 'BLOCKED — ${gate.blockedReason()}';
    stdout.writeln('  --${f.id.padRight(22)} (>=${f.minLanguageVersion})  $status');
  }
  stdout.writeln('\nEnable one or more feature flags to scan, e.g.:');
  stdout.writeln('  dart_modernizer lib --dot-shorthands');
}

bool _isDirtyGitTree(String packageRoot) {
  final res = Process.runSync('git', ['status', '--porcelain'],
      workingDirectory: packageRoot);
  if (res.exitCode != 0) return false; // not a git repo -> don't block
  return (res.stdout as String).trim().isNotEmpty;
}
