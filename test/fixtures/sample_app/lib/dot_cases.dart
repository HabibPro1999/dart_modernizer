// Fixture exercising dot-shorthand migration. Each `EXPECT:` comment states
// whether the marked expression should be shortened.

enum Mode { preview, native, feed }

enum PostType { image, video, reel }

class Sizes {
  const Sizes._();
  static const double small = 4;
  static const double large = 16;
  static double compute(int x) => x * 2.0;
}

class Swatch {
  final int v;
  const Swatch(this.v);
  static const Swatch red = Swatch(1);
  static const Swatch blue = Swatch(2);
}

class Widgety {
  final Mode mode;
  final PostType type;
  // EXPECT: Mode.native -> .native ; PostType.image -> .image
  const Widgety({this.mode = Mode.native, this.type = PostType.image});
}

void takesMode(Mode m) {}

void named({required Mode mode}) {}

// EXPECT: Mode.preview -> .preview (typed var initializer)
Mode varTyped = Mode.preview;

// EXPECT: PostType.reel -> .reel (sync return)
PostType funcReturn() => PostType.reel;

// EXPECT: both elements shortened (typed list literal)
final List<Mode> modes = [Mode.preview, Mode.native];

// EXPECT: both shortened (explicit type arguments supply the context)
final explicitModes = <Mode>[Mode.feed, Mode.native];

// EXPECT: NO (untyped literal; its element type is inferred upward from the
// elements, so shortening them would leave nothing to infer from)
const inferredModes = [Mode.preview, Mode.native];

// EXPECT: PostType.video -> .video (== right operand)
bool cmpRight(PostType t) => t == PostType.video;

// EXPECT: NO (== left operand cannot be a shorthand)
bool cmpLeft(PostType t) => PostType.video == t;

// EXPECT: all three patterns shortened (switch scrutinee is PostType)
String classify(PostType t) => switch (t) {
      PostType.image => 'i',
      PostType.video => 'v',
      PostType.reel => 'r',
    };

void calls() {
  // EXPECT: Mode.feed -> .feed (positional arg)
  takesMode(Mode.feed);
  // EXPECT: Mode.preview -> .preview (named arg)
  named(mode: Mode.preview);
}

// EXPECT: Swatch.red -> .red (static const, context type IS Swatch)
Swatch favourite = Swatch.red;

// EXPECT: NO (no declared type -> no context)
var inferred = Mode.native;

// EXPECT: NO (dynamic context)
dynamic dyn = Mode.native;

// EXPECT: NO (context type double != Sizes; `.small` would not resolve)
double sz = Sizes.small;

// EXPECT: NO (static method, not a field/enum constant)
double szc = Sizes.compute(3);
