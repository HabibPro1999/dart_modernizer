import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:pub_semver/pub_semver.dart';

import '../source_edit.dart';
import 'feature.dart';

/// Collapses the "public named parameter copied into a private field" boilerplate
/// into a private named initializing formal (Dart 3.12+), e.g.
///
///   class Point {
///     final int _x, _y;
///     Point({required int x, required int y}) : _x = x, _y = y;
///   }
///
/// becomes
///
///   class Point {
///     final int _x, _y;
///     Point({required this._x, required this._y});
///   }
///
/// Call sites are unaffected: `this._x` exposes the field name with the leading
/// underscore stripped, so the named argument keeps its public spelling
/// (`Point(x: 1, y: 2)`).
///
/// Scope (conservative — matches `dart fix --code=prefer_initializing_formals`):
/// only the *bare-copy* case is rewritten — a NAMED parameter with a public name
/// `p` whose sole use is one `_p = p` field initializer targeting a non-late,
/// non-static instance field named exactly `_p`. Transformed initializers
/// (`_x = x * 2`), positional params (always-legal initializing formals, out of
/// this feature's scope), super params, field-name mismatches (`_total = count`),
/// and parameters referenced more than once are left untouched.
class PrivateNamedParamsFeature implements Feature {
  @override
  String get id => 'private-named-params';

  @override
  String get displayName => 'Private named parameters';

  @override
  Version get minLanguageVersion => Version(3, 12, 0);

  @override
  int get priority => 20;

  @override
  bool get experimental => false;

  @override
  List<SourceEdit> collect(ResolvedUnitResult unit) {
    final visitor = _Visitor(unit);
    unit.unit.accept(visitor);
    return visitor.edits;
  }
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.unit);

  final ResolvedUnitResult unit;
  final List<SourceEdit> edits = [];

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _consider(node);
    super.visitConstructorDeclaration(node);
  }

  void _consider(ConstructorDeclaration node) {
    if (node.factoryKeyword != null) return;
    if (node.redirectedConstructor != null) return;
    final initializers = node.initializers;
    if (initializers.isEmpty) return;

    final rewrites = <_Rewrite>[];
    final removed = <ConstructorInitializer>{};

    for (final param in node.parameters.parameters) {
      if (!param.isNamed) continue;
      final inner = param is DefaultFormalParameter ? param.parameter : param;
      if (inner is! SimpleFormalParameter) continue; // skips this./super. formals
      final nameToken = inner.name;
      if (nameToken == null) continue;
      final publicName = nameToken.lexeme;
      if (publicName.startsWith('_')) continue;

      final paramElement = param.declaredFragment?.element;
      if (paramElement == null) continue;

      // The parameter's sole use must be one bare-copy field initializer.
      final init = _bareCopyInitializer(initializers, paramElement);
      if (init == null) continue;
      if (removed.contains(init)) continue; // two params, same field — bail out

      final field = _fieldOf(init.fieldName.element);
      if (field == null) continue;
      if (field.isStatic || field.isLate) continue;
      // Field must be the private spelling of the public name, so the exposed
      // argument name is unchanged.
      if (field.name != '_$publicName') continue;

      if (_referenceCount(node, paramElement) != 1) continue;

      rewrites.add(_Rewrite(inner, field.name!));
      removed.add(init);
    }

    if (rewrites.isEmpty) return;

    // 1. Each `[required] T name` parameter -> `[required] this._name`.
    for (final r in rewrites) {
      final start = r.param.type?.offset ?? r.param.name!.offset;
      final end = r.param.name!.end;
      edits.add(SourceEdit(
        offset: start,
        length: end - start,
        replacement: 'this.${r.fieldName}',
        featureId: 'private-named-params',
        priority: 20,
        line: unit.lineInfo.getLocation(start).lineNumber,
        description:
            '${r.param.name!.lexeme} -> this.${r.fieldName} (private named param)',
      ));
    }

    // 2. Drop the now-redundant initializers, preserving any others
    //    (asserts, super-calls, transformed field inits) verbatim.
    final kept = initializers.where((i) => !removed.contains(i)).toList();
    final regionEnd = initializers.last.end;
    if (kept.isEmpty) {
      // Remove the whole `: ...` clause, anchoring just past the `)`.
      final from = node.parameters.end;
      edits.add(SourceEdit(
        offset: from,
        length: regionEnd - from,
        replacement: '',
        featureId: 'private-named-params',
        priority: 20,
        line: unit.lineInfo.getLocation(from).lineNumber,
        description: 'drop ${removed.length} redundant initializer(s)',
      ));
    } else {
      final regionStart = initializers.first.offset;
      final rebuilt =
          kept.map((i) => unit.content.substring(i.offset, i.end)).join(', ');
      edits.add(SourceEdit(
        offset: regionStart,
        length: regionEnd - regionStart,
        replacement: rebuilt,
        featureId: 'private-named-params',
        priority: 20,
        line: unit.lineInfo.getLocation(regionStart).lineNumber,
        description: 'drop ${removed.length} redundant initializer(s)',
      ));
    }
  }

  /// The single `_field = <param>` initializer whose right-hand side is exactly
  /// [param], or null if there is no such bare copy.
  ConstructorFieldInitializer? _bareCopyInitializer(
    List<ConstructorInitializer> initializers,
    Element param,
  ) {
    for (final init in initializers) {
      if (init is! ConstructorFieldInitializer) continue;
      final rhs = init.expression;
      if (rhs is! SimpleIdentifier) continue;
      if (identical(rhs.element, param)) return init;
    }
    return null;
  }

  FieldElement? _fieldOf(Element? el) {
    if (el is FieldElement) return el;
    if (el is PropertyAccessorElement) {
      final v = el.variable;
      if (v is FieldElement) return v;
    }
    return null;
  }

  int _referenceCount(ConstructorDeclaration node, Element param) {
    final counter = _RefCounter(param);
    node.accept(counter);
    return counter.count;
  }
}

class _Rewrite {
  final SimpleFormalParameter param;
  final String fieldName;
  _Rewrite(this.param, this.fieldName);
}

class _RefCounter extends RecursiveAstVisitor<void> {
  _RefCounter(this.target);
  final Element target;
  int count = 0;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (identical(node.element, target)) count++;
    super.visitSimpleIdentifier(node);
  }
}
