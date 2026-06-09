import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:pub_semver/pub_semver.dart';

import '../source_edit.dart';
import 'feature.dart';

/// Rewrites verbose static access to a dot shorthand, e.g.
/// `VideoMode.native` -> `.native`, `FontWeight.w500` -> `.w500`,
/// `post.postType == PostType.reel` -> `post.postType == .reel`.
///
/// Scope (per project decision): enum constants and static-const fields only.
/// Static methods, constructors, and non-const statics are out of scope.
///
/// Every rewrite is gated on the *resolved* context type: the verbose `T.member`
/// is shortened only when the position's context type denotes exactly the same
/// declaration `T` (declaration identity), which is what makes the shorthand
/// resolve to the same member.
class DotShorthandsFeature implements Feature {
  @override
  String get id => 'dot-shorthands';

  @override
  String get displayName => 'Dot shorthands';

  @override
  Version get minLanguageVersion => Version(3, 10, 0);

  @override
  int get priority => 10;

  @override
  bool get experimental => false;

  @override
  List<SourceEdit> collect(ResolvedUnitResult unit) {
    final visitor = _DotShorthandVisitor(unit);
    unit.unit.accept(visitor);
    return visitor.edits;
  }
}

/// Classes whose members must never be shortened (instance-field token chains
/// like `AppDesignTokens.brand.primary`, where the value type is `Color`, not
/// the token class). Decl-identity already rejects these, but the name guard is
/// belt-and-suspenders.
const _hardExcludedTypeNames = <String>{'AppDesignTokens'};

class _DotShorthandVisitor extends RecursiveAstVisitor<void> {
  _DotShorthandVisitor(this.unit);

  final ResolvedUnitResult unit;
  final List<SourceEdit> edits = [];

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _consider(node);
    super.visitPrefixedIdentifier(node);
  }

  void _consider(PrefixedIdentifier node) {
    // 1. The member must be an enum constant or a static-const field.
    final field = _staticOrEnumField(node.element);
    if (field == null) return;
    if (!(field.isEnumConstant || (field.isStatic && field.isConst))) return;

    // 2. The declaration that owns the member.
    final decl = field.enclosingElement;
    if (decl is! InterfaceElement) return;
    if (_hardExcludedTypeNames.contains(decl.name)) return;

    // 3. The prefix the author wrote must denote that same declaration.
    if (node.prefix.element is! InterfaceElement) return;
    if (!identical(node.prefix.element, decl)) return;

    // 4. The position's context type must denote the same declaration.
    final ctxDecl = _contextDecl(node);
    if (ctxDecl == null || !identical(ctxDecl, decl)) return;

    // Emit: delete the type prefix, keeping `.member`.
    final period = node.period;
    final memberName = node.identifier.name;
    final offset = node.offset;
    final length = period.offset - offset; // removes `Prefix`, leaves `.member`
    if (length <= 0) return;
    edits.add(SourceEdit(
      offset: offset,
      length: length,
      replacement: '',
      featureId: 'dot-shorthands',
      priority: 10,
      line: unit.lineInfo.getLocation(offset).lineNumber,
      description: '${node.prefix.name}.$memberName -> .$memberName',
    ));
  }

  /// Resolves [el] to the backing [FieldElement] for an enum constant or a
  /// static field (the synthetic getter case), or null.
  FieldElement? _staticOrEnumField(Element? el) {
    if (el is FieldElement) return el;
    if (el is PropertyAccessorElement) {
      final v = el.variable;
      if (v is FieldElement) return v;
    }
    return null;
  }

  /// The declaration denoted by the static context type at [node]'s position,
  /// or null if the position has no usable context type.
  InterfaceElement? _contextDecl(Expression node) {
    final parent = node.parent;

    // Named argument: `name: VideoMode.native`.
    if (parent is NamedExpression && identical(parent.expression, node)) {
      return _declOf(parent.correspondingParameter?.type);
    }
    // Positional argument.
    if (parent is ArgumentList) {
      return _declOf(node.correspondingParameter?.type);
    }
    // Typed variable / field initializer: `VideoMode m = VideoMode.native;`.
    if (parent is VariableDeclaration && identical(parent.initializer, node)) {
      final list = parent.parent;
      if (list is VariableDeclarationList) return _declOf(list.type?.type);
      return null;
    }
    // `==` / `!=` right operand only.
    if (parent is BinaryExpression && identical(parent.rightOperand, node)) {
      final op = parent.operator.lexeme;
      if (op == '==' || op == '!=') return _declOf(parent.leftOperand.staticType);
      return null;
    }
    // Default value of a formal: `this.mode = VideoMode.native`.
    if (parent is DefaultFormalParameter && identical(parent.defaultValue, node)) {
      return _declOf(parent.declaredFragment?.element.type);
    }
    // Constant pattern in a switch: `case .reel =>`.
    if (parent is ConstantPattern && identical(parent.expression, node)) {
      return _declOf(_switchScrutineeType(parent));
    }
    // Typed list/set literal element.
    final elementType = _collectionElementType(node);
    if (elementType != null) return _declOf(elementType);
    // Direct (non-async) return / `=>` body.
    final returnType = _returnContextType(node);
    if (returnType != null) return _declOf(returnType);

    return null;
  }

  InterfaceElement? _declOf(DartType? t) =>
      t is InterfaceType ? t.element : null;

  DartType? _switchScrutineeType(AstNode node) {
    for (AstNode? a = node; a != null; a = a.parent) {
      if (a is SwitchExpression) return a.expression.staticType;
      if (a is SwitchStatement) return a.expression.staticType;
    }
    return null;
  }

  /// Element context type for a dot-shorthand inside a list/set literal, taken
  /// from the literal's *context* — author-written type arguments, or the type
  /// its surrounding position demands. Never from the literal's own
  /// `staticType`: for an untyped literal like `const xs = [Foo.bar]`, that type
  /// is inferred *upward* from the elements, so shortening them to `[.bar]`
  /// would erase the very information that produced the type and fail to resolve
  /// (the cause of the `notifications_screen.dart` verify failure).
  DartType? _collectionElementType(Expression node) {
    final parent = node.parent;
    final inList = parent is ListLiteral && parent.elements.contains(node);
    final inSet = parent is SetOrMapLiteral && parent.elements.contains(node);
    if (!inList && !inSet) return null;
    final literal = parent as TypedLiteral;

    // 1. Author-written type arguments: `<Foo>[...]` / `<Foo>{...}`.
    final typeArgs = literal.typeArguments?.arguments;
    if (typeArgs != null) {
      return typeArgs.length == 1 ? typeArgs.first.type : null;
    }

    // 2. The context type the surrounding position imposes on the literal
    //    (maps carry two type arguments and are skipped by the length check).
    final ctx = _contextTypeOf(literal);
    if (ctx is InterfaceType && ctx.typeArguments.length == 1) {
      return ctx.typeArguments.first;
    }
    return null;
  }

  /// The static context type imposed on [node] by its syntactic position, or
  /// null. Mirrors the positions [_contextDecl] handles but yields the full
  /// type, so a collection's element type can be read off its type arguments.
  DartType? _contextTypeOf(Expression node) {
    final parent = node.parent;
    if (parent is NamedExpression && identical(parent.expression, node)) {
      return parent.correspondingParameter?.type;
    }
    if (parent is ArgumentList) {
      return node.correspondingParameter?.type;
    }
    if (parent is VariableDeclaration && identical(parent.initializer, node)) {
      final list = parent.parent;
      if (list is VariableDeclarationList) return list.type?.type;
      return null;
    }
    return _returnContextType(node);
  }

  DartType? _returnContextType(Expression node) {
    final parent = node.parent;
    final isReturn = (parent is ReturnStatement && identical(parent.expression, node)) ||
        (parent is ExpressionFunctionBody && identical(parent.expression, node));
    if (!isReturn) return null;
    for (AstNode? a = node; a != null; a = a.parent) {
      if (a is FunctionBody && (a.isAsynchronous || a.isGenerator)) return null;
      if (a is MethodDeclaration) return a.returnType?.type;
      if (a is FunctionDeclaration) return a.returnType?.type;
    }
    return null;
  }
}
