// Fixture exercising private-named-parameter migration. Valid pre-3.12 syntax,
// so it resolves on the test toolchain; the feature's `collect()` is exercised
// directly (the pipeline would version-gate it out on a <3.12 toolchain).
//
// ignore_for_file: unused_field — the private fields model the pre-migration
// boilerplate; they are intentionally unread.

class Point {
  final int _x;
  final int _y;
  // EXPECT: both named params -> this._x / this._y, initializers dropped.
  Point({required int x, required int y})
      : _x = x,
        _y = y;
}

class Mixed {
  final int _a;
  final int b;
  // EXPECT: only `a` is rewritten; `this.b` is already a field formal.
  Mixed({required int a, required this.b}) : _a = a;
}

class Transformed {
  final int _v;
  // EXPECT: NO — initializer transforms the value (not a bare copy).
  Transformed({required int v}) : _v = v * 2;
}

class Renamed {
  final int _total;
  // EXPECT: NO — field `_total` strips to `total` != param `count`; rewriting
  // would change the public argument name and break call sites.
  Renamed({required int count}) : _total = count;
}

class Positional {
  final int _z;
  // EXPECT: NO — positional param (feature is named-only; `this._z` positional
  // was always legal and is out of scope).
  Positional(int z) : _z = z;
}

class UsedTwice {
  final int _n;
  final int _sq;
  // EXPECT: NO — `n` is referenced in two initializers (reference-flip risk).
  UsedTwice({required int n})
      : _n = n,
        _sq = n * n;
}
