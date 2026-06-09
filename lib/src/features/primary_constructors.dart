import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:pub_semver/pub_semver.dart';

import '../source_edit.dart';
import 'feature.dart';

/// Hoists an immutable data class's fields into a primary (declaring)
/// constructor (Dart 3.13 — experimental, behind
/// `--enable-experiment=primary-constructors`), e.g.
///
///   class Point {
///     final int x;
///     final int y;
///     const Point(this.x, this.y);
///   }
///
/// becomes
///
///   class const Point(final int x, final int y);
///
/// Scope (deliberately narrow for a first pass): a plain `class` whose body is
/// EXACTLY a set of `final`, typed, single-variable, non-late, non-static
/// instance fields with no initializer, plus ONE unnamed generative constructor
/// whose parameters are all required-positional `this.field` formals, with an
/// empty initializer list and empty body, in 1:1 correspondence with those
/// fields. Anything outside that shape — methods/getters, named/optional/super
/// parameters, non-final or initialized fields, annotations, doc comments, or
/// class modifiers (abstract/sealed/base/interface/final/mixin) — is skipped.
///
/// Output compiles only under language 3.13 with the `primary-constructors`
/// experiment enabled; the pipeline gates this feature accordingly.
class PrimaryConstructorsFeature implements Feature {
  @override
  String get id => 'primary-constructors';

  @override
  String get displayName => 'Primary constructors';

  @override
  Version get minLanguageVersion => Version(3, 13, 0);

  @override
  int get priority => 30;

  @override
  bool get experimental => true;

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
  void visitClassDeclaration(ClassDeclaration node) {
    _consider(node);
    super.visitClassDeclaration(node);
  }

  void _consider(ClassDeclaration node) {
    // Plain `class` only — modifiers change construction/subtyping semantics.
    if (node.abstractKeyword != null ||
        node.sealedKeyword != null ||
        node.baseKeyword != null ||
        node.interfaceKeyword != null ||
        node.finalKeyword != null ||
        node.mixinKeyword != null ||
        node.augmentKeyword != null) {
      return;
    }

    final ctors = node.members.whereType<ConstructorDeclaration>().toList();
    if (ctors.length != 1) return;
    final ctor = ctors.first;

    // One unnamed, generative, side-effect-free constructor.
    if (ctor.factoryKeyword != null ||
        ctor.externalKeyword != null ||
        ctor.augmentKeyword != null ||
        ctor.name != null ||
        ctor.redirectedConstructor != null) {
      return;
    }
    if (ctor.initializers.isNotEmpty) return;
    if (!_isEmptyBody(ctor.body)) return;
    if (ctor.metadata.isNotEmpty || ctor.documentationComment != null) return;

    // Every parameter must be a required-positional `this.field` formal.
    final params = ctor.parameters.parameters;
    if (params.isEmpty) return;
    final paramNames = <String>[];
    for (final p in params) {
      if (!p.isRequiredPositional) return;
      if (p is! FieldFormalParameter) return;
      if (p.parameters != null) return; // function-typed field formal
      if (p.metadata.isNotEmpty) return;
      paramNames.add(p.name.lexeme);
    }

    // The body must be exactly those fields plus the constructor.
    final fieldTypes = <String, String>{}; // field name -> type source text
    for (final member in node.members) {
      if (identical(member, ctor)) continue;
      if (member is! FieldDeclaration) return;
      if (member.isStatic) return;
      if (member.metadata.isNotEmpty || member.documentationComment != null) {
        return;
      }
      final list = member.fields;
      if (list.keyword?.lexeme != 'final') return;
      if (list.type == null) return;
      if (list.variables.length != 1) return;
      final v = list.variables.first;
      if (v.initializer != null) return;
      fieldTypes[v.name.lexeme] =
          unit.content.substring(list.type!.offset, list.type!.end);
    }

    // 1:1 field/parameter correspondence.
    if (fieldTypes.length != paramNames.length) return;
    for (final name in paramNames) {
      if (!fieldTypes.containsKey(name)) return;
    }

    // Declaring parameter list, in constructor-parameter order.
    final declared =
        paramNames.map((n) => 'final ${fieldTypes[n]} $n').join(', ');

    // Edit 1 (optional): `class Point` -> `class const Point`.
    if (ctor.constKeyword != null) {
      edits.add(SourceEdit(
        offset: node.name.offset,
        length: 0,
        replacement: 'const ',
        featureId: 'primary-constructors',
        priority: 30,
        line: unit.lineInfo.getLocation(node.name.offset).lineNumber,
        description: 'mark primary constructor const',
      ));
    }

    // Edit 2: splice the declaring parameter list in after the name/type
    // parameters and collapse the body, preserving any extends/with/implements
    // clauses verbatim.
    final insertAt = node.typeParameters?.end ?? node.name.end;
    final clauses =
        unit.content.substring(insertAt, node.leftBracket.offset).trimRight();
    edits.add(SourceEdit(
      offset: insertAt,
      length: node.rightBracket.end - insertAt,
      replacement: '($declared)$clauses;',
      featureId: 'primary-constructors',
      priority: 30,
      line: unit.lineInfo.getLocation(insertAt).lineNumber,
      description:
          '${node.name.lexeme} -> primary constructor (${paramNames.length} field(s))',
    ));
  }

  bool _isEmptyBody(FunctionBody body) {
    if (body is EmptyFunctionBody) return true;
    if (body is BlockFunctionBody) return body.block.statements.isEmpty;
    return false;
  }
}
