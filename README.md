# dart_modernizer

Analyzer-based codemod that migrates a Dart/Flutter codebase to modern language
features. Resolved-AST driven, **dry-run by default**, every edit re-analyzed
before it is kept.

## Features

| Flag | Migration | Min language | Status |
|------|-----------|--------------|--------|
| `--dot-shorthands` | `Mode.feed` → `.feed` | 3.10 | stable |
| `--private-named-params` | `Foo({required int x}) : _x = x;` → `Foo({required this._x});` | 3.12 | stable |
| `--primary-constructors` | `class Point { final int x; const Point(this.x); }` → `class const Point(final int x);` | 3.13 | experimental |

## How it works

1. **Resolve** every non-generated `.dart` file through the analyzer.
2. **Collect** candidate edits per feature, gated on the *resolved* context type —
   no edit unless it provably preserves meaning.
3. **Merge** overlapping edits by priority.
4. **Verify** — re-analyze each edited file in an in-memory overlay; drop the
   edit if it introduces any error.
5. **Report** a per-file diff + summary. Files are written only with `--apply`.

Two walls must clear before a feature runs: the package's declared SDK floor and
the installed toolchain must both meet the feature's minimum language version.
Experimental features additionally require `--enable-experiment`.

## Usage

```bash
cd dart_modernizer
dart pub get

# Gate status — what is usable in the target package
dart run bin/dart_modernizer.dart /path/to/app/lib

# Dry-run (default), with diffs
dart run bin/dart_modernizer.dart /path/to/app/lib --dot-shorthands

# Apply (refuses a dirty git tree without --force)
dart run bin/dart_modernizer.dart /path/to/app/lib \
  --dot-shorthands --private-named-params --apply
```

### Flags

| Flag | Effect |
|------|--------|
| `--<feature>` | enable a migration (see table) |
| `--apply` | write changes (default: dry-run) |
| `--no-diff` | hide per-file diffs |
| `--no-verify` | skip the re-analyze safety check |
| `--force` | allow `--apply` on a dirty git tree |
| `--enable-experiment=<id>` | opt into an experimental feature |

## Scope

Conservative by design — correctness over coverage:

- **dot-shorthands** — enum constants and static-const fields only, shortened
  solely where the position's context type names the same declaration.
- **private-named-params** — bare-copy case only (`_p = p` → `this._p`); the
  public argument name is preserved, so call sites are untouched.
- **primary-constructors** — plain data classes: final, typed fields plus one
  unnamed generative `this.field` constructor with an empty body.

Exclude lists (generated-file suffixes, repo-specific type/path excludes) live in
`lib/src/discovery.dart` and `lib/src/features/`. Adjust them for your project.

## Develop

```bash
dart test       # transform logic + fixtures
dart analyze
```

Add a feature: implement `Feature` in `lib/src/features/`, then register it in
`lib/src/cli.dart`. Its `--flag` and version gating wire up automatically.
