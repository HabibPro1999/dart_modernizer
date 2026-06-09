// Fixture exercising primary-constructor migration. Valid pre-3.13 syntax, so
// it resolves on the test toolchain; the feature's `collect()` is exercised
// directly (the pipeline would version-gate it out on a <3.13 toolchain).

// EXPECT: class const Point(final int x, final int y);
class Point {
  final int x;
  final int y;
  const Point(this.x, this.y);
}

// EXPECT: class Box<T>(final T value);  (non-const, generic)
class Box<T> {
  final T value;
  Box(this.value);
}

// EXPECT: NO — has a method, so the body is not exclusively fields + ctor.
class WithMethod {
  final int n;
  const WithMethod(this.n);
  int doubled() => n * 2;
}

// EXPECT: NO — non-final field.
class Mutable {
  int count;
  Mutable(this.count);
}

// EXPECT: NO — named constructor.
class Named {
  final int v;
  const Named.of(this.v);
}

// EXPECT: NO — non-empty initializer list and a field that is not a parameter.
class WithInit {
  final int a;
  final int b;
  WithInit(this.a) : b = 0;
}

// EXPECT: NO — plain (non-`this.`) parameter.
class PlainParam {
  final int x;
  PlainParam(int x) : x = x;
}
