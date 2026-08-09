module cherry.platform.render;

/**
 * The drawing model of the framework.  A rendering backend must implement
 * this model completely and with identical visual results -- a backend that
 * cannot express part of it is not a backend (the reason GDI is only ever a
 * blitter, never a renderer).
 */

/// An RGBA color; components in [0, 1].
struct Color
{
    float r = 0;
    float g = 0;
    float b = 0;
    float a = 1;

    static Color rgb(float r, float g, float b, float a = 1) pure nothrow @nogc
    {
        return Color(r, g, b, a);
    }

    enum white = Color(1, 1, 1, 1);
    enum black = Color(0, 0, 0, 1);
    enum transparent = Color(0, 0, 0, 0);
}

/// A point in device-independent coordinates.
struct Point
{
    float x = 0;
    float y = 0;
}

/// A size in device-independent coordinates.
struct Size
{
    float width = 0;
    float height = 0;
}

/**
 * An inset on each of the four sides of a rectangle: what an element keeps
 * clear around itself, and later what a border measures.
 *
 * Unlike Point, Size and Rect this one has constructors, so it has no implicit
 * field-wise literal -- and the shorthand reads differently from its
 * neighbours': `Thickness(4, 8)` is four left and right, eight top and bottom,
 * where `Rect(4, 8)` would be x and y.  The two-argument form is the one
 * people reach for and is worth the asymmetry, but it is worth knowing about.
 *
 * Equality is the compiler's, field by field, which is what user code wants.
 * The property system does not use it: a struct-typed Value is compared byte
 * for byte (see valueEquals in cherry.core.value), so an opEquals here would
 * have no say in whether assigning a margin counts as a change, and writing
 * one would only suggest otherwise.
 */
struct Thickness
{
    float left = 0;
    float top = 0;
    float right = 0;
    float bottom = 0;

    /// The same amount on every side.
    this(float uniform) pure nothrow @nogc
    {
        left = top = right = bottom = uniform;
    }

    /// One amount left and right, another top and bottom.
    this(float horizontal, float vertical) pure nothrow @nogc
    {
        left = right = horizontal;
        top = bottom = vertical;
    }

    /// Each side its own, in the order they are named.
    this(float left, float top, float right, float bottom) pure nothrow @nogc
    {
        this.left = left;
        this.top = top;
        this.right = right;
        this.bottom = bottom;
    }

   /**
    * The width an element gives away to its margin, and the height.
    *
    * The sizing pass asks for these two and never for the four sides: what it
    * takes out of the space on offer, and what it puts back onto the answer,
    * is a pair of totals.  Only the placing pass cares which side is which.
    */
    @property float horizontal() pure const nothrow @nogc { return left + right; }

    /// ditto
    @property float vertical() pure const nothrow @nogc { return top + bottom; }
}

unittest
{
    // The three ways to say a thickness, and the two sums layout asks for.
    assert(Thickness(5) == Thickness(5, 5, 5, 5));
    assert(Thickness(10, 20) == Thickness(10, 20, 10, 20),
           "horizontal first and then vertical -- not left and then top");

    immutable t = Thickness(1, 2, 3, 4);
    assert(t.left == 1 && t.top == 2 && t.right == 3 && t.bottom == 4);
    assert(t.horizontal == 4 && t.vertical == 6);

    assert(Thickness.init == Thickness(0),
           "nothing around it, which is what an element has until told otherwise");
}

/// An axis-aligned rectangle: origin plus size.
struct Rect
{
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;

    @property float right() pure const nothrow @nogc { return x + width; }
    @property float bottom() pure const nothrow @nogc { return y + height; }

   /**
    * Whether the rectangle covers nothing.
    *
    * Written as a pair of refusals rather than as `width <= 0`, so that a NaN
    * extent counts as empty instead of as neither -- the same reasoning the
    * layout arithmetic uses at its own edges.  What it buys is that `Rect.init`
    * is a usable accumulator: a union starting there is the union of what is
    * put into it and nothing else, and an element that has never been arranged
    * contributes nothing rather than dragging the answer to the origin.
    */
    @property bool empty() pure const nothrow @nogc
    {
        return !(width > 0) || !(height > 0);
    }

   /**
    * Whether the point falls inside, with the left and top edges belonging to
    * the rectangle and the right and bottom edges belonging to whatever is
    * next along.
    *
    * Half-open on purpose.  Two elements laid end to end share a coordinate,
    * and a closed test would put every point of that line in both of them --
    * so which one a click landed on would depend on the order they happened to
    * be tested in.  The same rule makes an empty rectangle contain nothing,
    * which agrees with `empty`, and leaves a NaN coordinate outside everything,
    * because both comparisons are false.
    */
    bool contains(Point point) pure const nothrow @nogc
    {
        return point.x >= x && point.x < right
            && point.y >= y && point.y < bottom;
    }

   /**
    * The smallest rectangle covering both, with an empty operand ignored --
    * in either position, so that folding a list into `Rect.init` gives the
    * union of the list.
    *
    * Named unite because union is a keyword.
    */
    Rect unite(Rect other) pure const nothrow @nogc
    {
        if (other.empty)
            return this;
        if (empty)
            return other;

        immutable left   = x < other.x ? x : other.x;
        immutable top    = y < other.y ? y : other.y;
        immutable right_ = this.right  > other.right  ? this.right  : other.right;
        immutable bottom_= this.bottom > other.bottom ? this.bottom : other.bottom;

        return Rect(left, top, right_ - left, bottom_ - top);
    }
}

unittest
{
    // What counts as covering nothing.  The NaN case is the one that matters:
    // it is how a rectangle derived from an unarranged element arrives, and
    // treating it as neither empty nor real would put it in a union.
    assert(Rect.init.empty);
    assert(Rect(10, 20, 0, 50).empty);
    assert(Rect(10, 20, 50, 0).empty);
    assert(Rect(10, 20, -5, 50).empty);
    assert(Rect(10, 20, float.nan, 50).empty);
    assert(!Rect(0, 0, 1, 1).empty);
}

unittest
{
    // Which points belong to a rectangle, and which belong to its neighbour.
    immutable r = Rect(10, 20, 100, 50);

    assert(r.contains(Point(10, 20)), "the near corner is inside");
    assert(r.contains(Point(109.99f, 69.99f)));
    assert(r.contains(Point(50, 40)));

    assert(!r.contains(Point(110, 40)), "and the far edge is not");
    assert(!r.contains(Point(50, 70)));
    assert(!r.contains(Point(9.99f, 40)));

    // Laid end to end, the shared line belongs to exactly one of them.
    immutable left  = Rect(0, 0, 50, 20);
    immutable right = Rect(50, 0, 50, 20);
    assert(!left.contains(Point(50, 10)) && right.contains(Point(50, 10)));

    assert(!Rect.init.contains(Point(0, 0)), "nothing is inside nothing");
    assert(!r.contains(Point(float.nan, 40)));
}

unittest
{
    // The union is the bounding box, and an empty operand is not in it.
    immutable a = Rect(0, 0, 10, 10);
    immutable b = Rect(20, 30, 10, 10);

    assert(a.unite(b) == Rect(0, 0, 30, 40));
    assert(b.unite(a) == a.unite(b), "and it does not matter which way round");

    assert(a.unite(Rect.init) == a);
    assert(Rect.init.unite(a) == a, "which is what makes Rect.init an accumulator");
    assert(a.unite(a) == a);

    // Nested: the larger one already covers the smaller.
    immutable outer = Rect(0, 0, 100, 100);
    assert(outer.unite(Rect(10, 10, 5, 5)) == outer);
}

/**
 * An affine transform: the 3x2 every drawing system means by that phrase.
 *
 * Row vectors, as in Direct2D, GDI+ and WPF.  A point is the row `[x y 1]`,
 * it goes on the left, and the third column is implicitly `[0 0 1]`:
 *
 *     p' = p * M      M = | m11 m12 0 |     x' = x*m11 + y*m21 + dx
 *                         | m21 m22 0 |     y' = x*m12 + y*m22 + dy
 *                         | dx  dy  1 |
 *
 * Because `p * (A * B)` is `(p * A) * B`, **`A * B` means "apply A, then B"**
 * -- reading left to right is reading in the order things happen.  Systems
 * built on column vectors read the other way, and a matrix copied out of one
 * of those, transposed and composed backwards, looks almost right: it agrees
 * exactly for translations, and translations commute, so the mistake only
 * shows the first time something is scaled or turned.
 *
 * `Matrix.init` is the identity, which is what makes a Matrix field, an array
 * element and an untouched transform stack all start neutral with nobody
 * writing initialisation code.
 *
 * Constructor-free, like Point, Size and Rect -- so a field-wise literal
 * stays available, and so the identity has one place to be spelled.  The
 * price is the same trap Thickness carries: a partial literal fills the rest
 * from the defaults, so `Matrix(2)` is a scale along x alone rather than
 * "twice as big".  Matrix.scaling is the thing that was meant.
 */
struct Matrix
{
    float m11 = 1;
    float m12 = 0;
    float m21 = 0;
    float m22 = 1;
    float dx  = 0;
    float dy  = 0;

    /// The transform that changes nothing.
    enum identity = Matrix(1, 0, 0, 1, 0, 0);

    /// Moves by an offset.
    static Matrix translation(float x, float y) pure nothrow @nogc
    {
        return Matrix(1, 0, 0, 1, x, y);
    }

    /// Scales about the origin.
    static Matrix scaling(float x, float y) pure nothrow @nogc
    {
        return Matrix(x, 0, 0, y, 0, 0);
    }

   /**
    * Turns about the origin, in degrees -- nobody writes a control rotated by
    * pi over two.
    *
    * A positive angle turns clockwise on screen, because y runs downwards
    * here; that is Direct2D's and WPF's direction too.
    *
    * The four quarter turns are answered exactly instead of through sin and
    * cos, so that turning a thing by ninety degrees and back leaves it where
    * it started rather than a rounding error away from it -- and so that a
    * test can say what it means with ==.
    */
    static Matrix rotation(float degrees) pure nothrow @nogc
    {
        immutable turn = degrees % 360;
        immutable positive = turn < 0 ? turn + 360 : turn;

        if (positive == 0)   return Matrix(1, 0, 0, 1, 0, 0);
        if (positive == 90)  return Matrix(0, 1, -1, 0, 0, 0);
        if (positive == 180) return Matrix(-1, 0, 0, -1, 0, 0);
        if (positive == 270) return Matrix(0, -1, 1, 0, 0, 0);

        import std.math : cos, sin, PI;

        immutable radians = positive * (PI / 180);
        immutable c = cast(float) cos(radians);
        immutable s = cast(float) sin(radians);

        return Matrix(c, s, -s, c, 0, 0);
    }

   /**
    * Composes: the result applies this one first and then the other.
    *
    * `translation(10, 0) * scaling(2, 2)` therefore takes the origin to
    * (20, 0) -- moved to ten, then doubled -- while the same two the other
    * way round take it to (10, 0).
    */
    Matrix opBinary(string op : "*")(Matrix rhs) const pure nothrow @nogc
    {
        return Matrix(
            m11 * rhs.m11 + m12 * rhs.m21,
            m11 * rhs.m12 + m12 * rhs.m22,
            m21 * rhs.m11 + m22 * rhs.m21,
            m21 * rhs.m12 + m22 * rhs.m22,
            dx  * rhs.m11 + dy  * rhs.m21 + rhs.dx,
            dx  * rhs.m12 + dy  * rhs.m22 + rhs.dy);
    }

   /**
    * Where a point ends up.
    *
    * A named method rather than an operator: both `p * m` and `m * p` are
    * things a reader will try to write, one of them would have to be a
    * silent transpose, and this is the axis the whole design is most likely
    * to go wrong on.  One direction, one name.
    */
    Point transform(Point point) const pure nothrow @nogc
    {
        return Point(point.x * m11 + point.y * m21 + dx,
                     point.x * m12 + point.y * m22 + dy);
    }
}

// Not an accident and not decoration: every backend has a 3x2 of its own with
// these six floats in this order, and one is entitled to hand its own type a
// pointer to one of these rather than copying field by field.
static assert(Matrix.sizeof == 6 * float.sizeof);

// Deliberately absent, so that nobody assumes they were forgotten: scaleAt and
// rotateAt (each is translation(-c) * op * translation(c), one line where it is
// wanted), invert and determinant (nothing inverts a transform until there is
// hit-testing), and transformBounds -- under a turn there is no such thing as
// the transformed rectangle, only a box around it, which is a different
// operation deserving a different name.

unittest
{
    // The identity is what an untouched Matrix already is.  This is the
    // assertion that breaks, silently and everywhere, if a field default is
    // ever dropped or the six are reordered.
    assert(Matrix.init == Matrix.identity);
    assert(Matrix.identity.transform(Point(3, 4)) == Point(3, 4));

    assert(Matrix.translation(10, 20).transform(Point(3, 4)) == Point(13, 24));
    assert(Matrix.scaling(2, 3).transform(Point(3, 4)) == Point(6, 12));

    immutable m = Matrix.translation(7, 9);
    assert(m * Matrix.identity == m);
    assert(Matrix.identity * m == m);
}

unittest
{
    // Composition order, which is the one thing here worth getting right.
    immutable t = Matrix.translation(10, 0);
    immutable s = Matrix.scaling(2, 2);

    assert((t * s).transform(Point(0, 0)) == Point(20, 0),
           "A * B is A first and then B: moved to ten, then doubled");
    assert((s * t).transform(Point(0, 0)) == Point(10, 0),
           "and the other way round is a different matrix");

    // The convention itself, written down as something that can fail.
    immutable p = Point(3, 4);
    assert((t * s).transform(p) == s.transform(t.transform(p)));

    // Associative, on values that are exact in binary so == means what it says.
    immutable a = Matrix.translation(4, 8);
    immutable b = Matrix.scaling(0.5, 2);
    immutable c = Matrix.translation(-1, 3);
    assert(((a * b) * c).transform(p) == (a * (b * c)).transform(p));
}

unittest
{
    // A quarter turn is answered exactly, and turns clockwise because y is
    // down: x goes to y.
    assert(Matrix.rotation(90).transform(Point(1, 0)) == Point(0, 1));
    assert(Matrix.rotation(180).transform(Point(1, 0)) == Point(-1, 0));
    assert(Matrix.rotation(270).transform(Point(1, 0)) == Point(0, -1));
    assert(Matrix.rotation(-90).transform(Point(0, 1)) == Point(1, 0));

    assert(Matrix.rotation(0) == Matrix.identity);
    assert(Matrix.rotation(360) == Matrix.identity, "all the way round is nowhere");
    assert(Matrix.rotation(450) == Matrix.rotation(90));
}

/**
 * The transform stack a DrawingContext keeps: what is in effect now, and what
 * to go back to.
 *
 * Every implementation of the model needs one and they would all be this, so
 * here it is once -- and, more to the point, the composition in push is
 * written down once.  That single line is the highest-risk statement in the
 * whole of the drawing model: getting the order backwards looks almost right,
 * because translations commute and translations are nearly all a layout ever
 * pushes.
 *
 * `.init` is a valid empty stack at the identity, which is where a context
 * begins a frame.
 */
struct TransformStack
{
    // Only ever a field of a context, so it is never copied -- but a copy
    // would silently share the array, so it is not allowed to happen.
    @disable this(this);

   /**
    * Enters a space expressed in the one currently in effect.
    *
    * A point p of the new space reaches the current one as `p * transform`,
    * and the current one reaches the target as `* current`, so the composite
    * is `transform * current` -- the new transform on the left.
    */
    void push(Matrix transform)
    {
        _saved ~= _current;
        _current = transform * _current;
    }

   /**
    * Goes back to the transform the matching push found.
    *
    * The previous value is kept rather than reached by undoing the push.  A
    * transform with a zero scale has no inverse and must still be poppable,
    * and an inverse would accumulate rounding all the way down a deep tree,
    * so a leaf would sit fractionally away from where it belongs.
    */
    void pop()
    in {
        assert(_saved.length > 0, "popTransform without a matching pushTransform.");
    }
    do {
        _current = _saved[$ - 1];
        _saved = _saved[0 .. $ - 1];
        _saved.assumeSafeAppend();
    }

    /// What maps the space being drawn in now to the target's own.
    @property Matrix current() const pure nothrow @nogc
    {
        return _current;
    }

    /// How many pushes are outstanding.  Zero at the start and end of a frame.
    @property size_t depth() const pure nothrow @nogc
    {
        return _saved.length;
    }

   /**
    * Back to an empty stack at the identity, whatever the last frame left.
    *
    * assumeSafeAppend here and in pop is what keeps a settled frame from
    * allocating: the array grows to the depth of the tree once and is reused
    * for the life of the context.
    */
    void reset() nothrow
    {
        _current = Matrix.init;
        _saved.length = 0;
        _saved.assumeSafeAppend();
    }

private:
    Matrix   _current;   // Matrix.init is the identity
    Matrix[] _saved;
}

unittest
{
    TransformStack s;

    assert(s.current == Matrix.identity);
    assert(s.depth == 0);

    s.push(Matrix.translation(10, 20));
    assert(s.depth == 1);
    assert(s.current.transform(Point(0, 0)) == Point(10, 20));

    // The inner push is expressed in the space the outer one entered.
    s.push(Matrix.translation(5, 5));
    assert(s.current.transform(Point(0, 0)) == Point(15, 25));

    s.pop();
    assert(s.current == Matrix.translation(10, 20), "exactly what it was, not something reconstructed");

    s.pop();
    assert(s.current == Matrix.identity);
    assert(s.depth == 0);
}

unittest
{
    // Popping goes back to a value that was kept, which is why a transform
    // with no inverse is still poppable.  An implementation that undid the
    // push by multiplying through an inverse cannot pass this.
    TransformStack s;

    s.push(Matrix.translation(3, 7));
    s.push(Matrix.scaling(0, 0));

    s.pop();
    assert(s.current == Matrix.translation(3, 7));
}

unittest
{
    // Whatever a frame left behind, the next one starts clean.
    TransformStack s;

    s.push(Matrix.translation(1, 1));
    s.push(Matrix.scaling(2, 2));
    s.push(Matrix.rotation(90));
    assert(s.depth == 3);

    s.reset();
    assert(s.depth == 0);
    assert(s.current == Matrix.identity);
}

/**
 * One colour along a gradient, and how far along it sits.
 *
 * `offset` runs from 0 at the start of the gradient to 1 at its end, whatever
 * the gradient's real length -- so a set of stops describes a ramp rather than
 * a size, and the same ones fill a button and a window equally.
 *
 * A struct and not an object, which costs the ability to animate one stop of a
 * gradient while leaving the rest alone.  WPF pays for that with a whole
 * Freezable per stop; here the brush is the animatable thing and the ramp goes
 * with it.  The day one stop needs to move on its own, this becomes a class and
 * the arrays below become collections.
 */
struct GradientStop
{
    float offset = 0;
    Color color;
}

/**
 * What a gradient does outside the span between its ends.
 *
 * The names are WPF's GradientSpreadMethod.  Direct2D calls the same three
 * CLAMP, WRAP and MIRROR.
 */
enum GradientSpread
{
    /// The end colours carry on forever.
    pad,
    /// The ramp turns round and runs back.
    reflect,
    /// The ramp starts over.
    repeat
}

/**
 * Something a drawing context can fill with.
 *
 * The drawing model needs to know what a fill looks like and nothing else --
 * not that it has properties, not that it can be animated or bound, not that it
 * sits in a tree.  Those belong to the object on the other side of this seam,
 * which the UI layer calls a Brush; this is the little of it that has to reach
 * down here.
 *
 * The split is not taste.  A context lives in cherry.platform and a Brush is a
 * StyledElement in cherry.ui, and the dependencies run ui -> core -> platform:
 * a class from up there cannot appear in a signature down here, but an
 * interface declared here can be implemented up there.
 *
 * A backend asks which kind it has by casting to one of the interfaces below,
 * and must cope with a Paint that is none of them by not drawing -- a kind it
 * has never heard of is a kind it cannot render.
 */
interface Paint
{
   /**
    * A number that changes whenever this paint would look different.
    *
    * The whole of what a backend needs to know to tell a device resource it has
    * built and cached from one that has gone stale.  Anything cheaper -- asking
    * every field, rebuilding every frame -- is either wrong or slow, and
    * anything richer would mean the paint knowing who is caching it.
    */
    @property ulong revision() const;
}

/// A paint that is one colour everywhere.
interface SolidPaint : Paint
{
    @property Color color() const;
}

/**
 * A paint that ramps between colours along a line.
 *
 * **The ends are fractions of what is being filled**, not lengths: (0, 0) is
 * its top left corner and (1, 1) its bottom right, so `start` at (0, 0) and
 * `end` at (0, 1) is top to bottom whatever the shape turns out to be.  That is
 * WPF's RelativeToBoundingBox, and it is the only mode here because the other
 * one is useless to a control whose size the layout decides: a button cannot
 * name its own height in a brush written before it was measured.
 *
 * What it costs the backend is that the shape being filled has to reach the
 * paint -- a fill knows its own bounds, so the conversion happens there.
 */
interface GradientPaint : Paint
{
    @property Point start() const;
    /// ditto
    @property Point end() const;

    /// The ramp, in the order it was given.
    @property const(GradientStop)[] stops() const;

    /// What happens outside the span between the ends.
    @property GradientSpread spread() const;
}

unittest
{
    // A stop nobody has touched is the start of the ramp in the default
    // colour, which is what makes GradientStop[] usable as a property value.
    immutable stop = GradientStop.init;

    assert(stop.offset == 0);
    assert(stop.color == Color.black, "Color's own default, opaque");

    assert(GradientSpread.init == GradientSpread.pad,
           "the ends carry on, which is the answer nobody has to think about");
}

/**
 * How heavy the strokes of a face are, on the scale every font format uses.
 *
 * The numbers are the weights themselves rather than an ordinal, because they
 * are the same numbers in OpenType, in CSS, in DirectWrite and in a font's own
 * name table: 400 is regular and 700 is bold wherever the question is asked.
 * That also leaves room between the members, so a face at 350 can be named
 * later without renumbering anything.
 */
enum FontWeight
{
    thin       = 100,
    extraLight = 200,
    light      = 300,
    semiLight  = 350,
    normal     = 400,
    medium     = 500,
    semiBold   = 600,
    bold       = 700,
    extraBold  = 800,
    black      = 900
}

/**
 * Upright, slanted, or a face drawn slanted.
 *
 * Oblique and italic are not the same thing and the distinction is the whole
 * reason there are three: oblique is the upright face sheared over, italic is
 * a face the designer drew separately, and in a serif family they do not even
 * have the same letterforms.  A family with no italic falls back to oblique on
 * its own, so asking for italic is always safe.
 */
enum FontStyle
{
    normal,
    oblique,
    italic
}

/// Whether a run of text may be broken across lines to fit the room it is in.
enum TextWrapping
{
    noWrap,
    wrap
}

/**
 * Which of the two pictures of "the system font" the text is drawn as.
 *
 * There is no single answer on Windows, which is why this is a setting and not
 * a decision the backend makes quietly.  The desktop of Windows 11 -- its
 * title bars, Explorer, the Start menu, Edge -- is drawn one way; a MessageBox
 * and every classic dialog behind it are drawn the other.  Both are the
 * system, and they do not look alike.
 *
 * The names are WPF's TextFormattingMode, and each is one DirectWrite call:
 *
 *   display -- CreateGdiCompatibleTextLayout with GDI_CLASSIC rasterisation.
 *              Glyphs are fitted to the pixel grid and advances are whole
 *              pixels, so text is crisp and slightly tighter, and identical to
 *              what a Win32 control puts on the screen.  It is the default,
 *              because a framework's first controls should be mistakable for
 *              the platform's.
 *
 *   ideal   -- CreateTextLayout with the monitor's own rasterisation.
 *              Sub-pixel positioning and unrounded advances, so the spacing
 *              the designer drew survives, and so text that is scaled or
 *              animated stays proportioned instead of stepping.
 *
 * The mode is part of the format rather than a property of the backend
 * precisely because it changes the measured size: the same string is a
 * different width in the two, and a decision that changes measurement has to
 * be visible to whatever measures.
 *
 * Deliberately absent: DirectWrite's third answer, GDI_NATURAL -- hinted
 * glyphs at unrounded advances.  It is literally the useGdiNatural flag of the
 * same call and is one more member here on the day something wants it.
 */
enum TextRendering
{
    display,
    ideal
}

/**
 * Everything about how a run of text should look, gathered into one value.
 *
 * Not a property value, and it must not become one.  A Value compares a struct
 * byte for byte, so a struct with a string in it would be compared by the
 * string's pointer rather than by its characters: two identical family names
 * built separately would look like a change on every assignment, and every
 * assignment would invalidate the layout.  Strings on their own compare
 * structurally, so the parts of this are what a control registers, and the
 * whole is assembled at the moment it measures.
 *
 * An empty family means the system's, which is what makes `TextFormat.init`
 * plus a size a usable request.
 */
struct TextFormat
{
    string        family;
    float         size      = 12;
    FontWeight    weight    = FontWeight.normal;
    FontStyle     style     = FontStyle.normal;
    TextWrapping  wrapping  = TextWrapping.noWrap;
    TextRendering rendering = TextRendering.display;
}

/**
 * A run of text that has been laid out and can report its size and be drawn.
 *
 * One object does both on purpose.  Measuring through one path and drawing
 * through another gives the two a chance to disagree -- about the wrap points,
 * about the last line's height, about a fallback font chosen for a character
 * the family does not have -- and the disagreement shows up as text that does
 * not fit the box the layout was given.  What was measured is what gets drawn
 * because they are the same object.
 *
 * Immutable once made: the format and the room were fixed when it was created,
 * and a caller that needs different ones asks the service for another.  That is
 * what lets a control keep one of these across frames and only rebuild it when
 * something it depends on has really changed.
 */
interface TextLayout
{
    /// The room the text actually takes, in device-independent coordinates.
    @property Size size();

    /// What was laid out, and how it was asked for.
    @property string text();

    /// ditto
    @property TextFormat format();

   /**
    * Releases whatever the backend is holding.  Using the layout afterwards is
    * a programming error.
    *
    * Explicit rather than left to the collector, because a backend layout owns
    * a native object and a control replaces its layout on every change of text
    * or font -- often enough that waiting for a collection is waiting too long.
    * An implementation should still survive not being told.
    */
    void dispose();
}

/**
 * Lays text out and answers how big it is -- the text seam of the PAL.
 *
 * Separate from DrawingContext, and it has to be: a context exists only inside
 * a frame, while measuring happens in the layout pass, long before there is
 * one and whether or not there is a window at all.  An element that could only
 * find out how big its text was while drawing could never ask for the right
 * amount of room.
 */
interface TextService
{
   /**
    * Lays the text out for the format given, in the room given.
    *
    * `available` is the room the caller has, not a promise about the answer:
    * a layout that does not wrap reports the width it needs even when that is
    * more than was offered, because an element that overflows should be seen
    * doing it.  What the room does decide is where a wrapping layout breaks.
    *
    * An infinite dimension is the question "how big would you like to be?",
    * and is what a measure pass with no constraint passes down.
    */
    TextLayout createLayout(string text, TextFormat format, Size available);
}

unittest
{
    // What a format nobody has touched asks for: the system's family at a
    // readable size, upright, unwrapped, drawn the way a Win32 control is.
    immutable f = TextFormat.init;

    assert(f.family is null, "empty means the system's, which is a request and not a gap");
    assert(f.size == 12);
    assert(f.weight == FontWeight.normal && f.style == FontStyle.normal);
    assert(f.wrapping == TextWrapping.noWrap);
    assert(f.rendering == TextRendering.display);

    // The weights are the weights, not an enumeration of them.
    assert(FontWeight.normal == 400 && FontWeight.bold == 700);
}

/**
 * The surface elements draw onto during a frame.  Solid colors only for
 * now; brush objects, clips and text join the model as the framework grows.
 *
 * Everything is drawn in the coordinate space currently in effect, which
 * starts each frame as the target's own and is changed by pushTransform.
 * A length -- a strokeWidth -- is a length in that space too, so it scales
 * with it.  Under the plain translations a layout pushes nothing changes;
 * the day something is scaled it does, and a reader should not have to find
 * that out from the screen.
 */
interface DrawingContext
{
   /**
    * Fills the whole target with the color, ignoring the current transform.
    *
    * clear is a frame's opening move rather than a drawing primitive: it has
    * no geometry of its own to transform, and what it fills is the whole
    * target however deep in a coordinate space the caller happens to be.
    * Calling it from inside an element therefore clears the window and not
    * the element, which is why it is only meaningful with nothing pushed --
    * and why an implementation may refuse it when something is.
    */
    void clear(Color color);

   /**
    * Fills and strokes, each with a paint rather than a colour.
    *
    * A paint that is a gradient reads its ends as fractions of what is being
    * filled, so every one of these hands the paint its own geometry: the
    * rectangle for the rectangles and the ellipses, the segment's bounding box
    * for a line.  That is the whole reason a fill has to know what it is
    * filling and cannot simply be handed a colour.
    *
    * A stroke is a paint and a width and nothing else.  A Pen -- dashes, caps,
    * joins -- is a thing of its own and is not here yet; when it arrives these
    * take one instead of the pair.
    */
    void fillRectangle(Rect rect, Paint paint);

    /// ditto
    void drawRectangle(Rect rect, Paint paint, float strokeWidth = 1);

    /// ditto
    void fillEllipse(Rect bounds, Paint paint);

    /// ditto
    void drawEllipse(Rect bounds, Paint paint, float strokeWidth = 1);

    /// ditto
    void drawLine(Point from, Point to, Paint paint, float strokeWidth = 1);

   /**
    * Draws a laid-out run of text, its top left corner at the origin.
    *
    * The top left of the box and not the baseline, so that text can be placed
    * by something that has not measured it -- which is what an element doing
    * its own arrangement is.  The baseline is inside the layout, where the
    * font knows where it is.
    *
    * The layout must have come from this thread's TextService.  A backend is
    * entitled to insist on its own kind and to say so loudly, because the
    * alternative is drawing nothing and leaving the caller to wonder.
    */
    void drawText(TextLayout layout, Point origin, Paint paint);

   /**
    * Enters a coordinate space of its own, expressed in the one in effect.
    *
    * A point p of the new space reaches the current one as `p * transform`,
    * and the current one reaches the target as `* currentTransform`, so what
    * takes effect is `transform * currentTransform` -- the new one on the
    * left.  See Matrix for why that order is what it is.
    */
    void pushTransform(Matrix transform);

   /**
    * Leaves the space the matching pushTransform entered, going back to the
    * transform that was in effect before it.
    *
    * Back to a value that was kept, not to one worked out by undoing the
    * push: a transform with a zero scale has no inverse and must still be
    * poppable.  Popping with nothing pushed is a programming error.
    */
    void popTransform();

   /**
    * What maps the space being drawn in now to the target's own.
    *
    * Read-only: push and pop are the only way to change it, which is what
    * keeps the stack the one account of where things are.
    */
    @property Matrix currentTransform();
}

/**
 * Renders frames into a platform window -- the rendering seam of the PAL.
 * Implementations own their device resources and recover from device loss
 * internally.
 */
interface WindowRenderer
{
   /**
    * Renders one frame: prepares the target, hands a live DrawingContext to
    * the callback, then presents.
    *
    * The context arrives with an empty transform stack at the identity, every
    * frame, whatever the frame before it left behind.  That is a promise to
    * the code that draws and a requirement on whoever implements this: the
    * frame that leaves the stack unbalanced is the one an element threw out
    * of, so putting it right belongs at the start of the next frame rather
    * than at the end of that one.
    */
    void render(scope void delegate(DrawingContext) draw);

   /**
    * Notifies the renderer that the window's client area changed size.
    */
    void resize(int width, int height);

   /**
    * Releases the device resources.  The renderer must not be used after.
    */
    void dispose();
}

version (unittest)
{
   /**
    * The smallest thing that is a paint: one colour that never changes.
    *
    * Every test that draws needs something to draw with, and the real brushes
    * live in cherry.ui -- which this module sits below and must not import.
    * This is what a test paints with, here and in the layers above.
    */
    class FakeSolidPaint : SolidPaint
    {
        this(Color color)
        {
            _color = color;
        }

        @property ulong revision() const { return 1; }
        @property Color color() const { return _color; }

    private:
        Color _color;
    }

   /**
    * A DrawingContext that writes down what was drawn and where it landed.
    *
    * Every primitive is recorded with the current transform already applied,
    * so a test asserts absolute numbers in the target's own space and never
    * works the composition out for itself.  That is the whole point of it: a
    * fake that recorded the coordinates it was handed would agree perfectly
    * with a caller who had the composition backwards.
    */
    class RecordingContext : DrawingContext
    {
        enum Kind { clear, fillRectangle, drawRectangle, fillEllipse, drawEllipse, line, text }

       /**
        * One recorded primitive.  rect carries the transformed bounds of the
        * four rectangle-shaped kinds, from and to the transformed ends of a
        * line; only the fields the kind uses mean anything.
        *
        * strokeWidth is recorded as it was passed.  It is a length in the
        * space that was in effect, and scaling it is the backend's business
        * rather than this record's.
        */
        static struct Entry
        {
            Kind   kind;
            Rect   rect;
            Point  from;
            Point  to;
           /**
            * The colour the paint resolved to, for a solid one -- and
            * Color.transparent for anything else.
            *
            * Kept beside the paint rather than replaced by it because almost
            * every test is about a flat fill and would rather read a colour
            * than cast an interface.  A gradient test reads `paint`.
            */
            Color  color;
            float  strokeWidth = 0;
            Matrix transform;

           /**
            * What was written, for the text kind and nothing else.
            *
            * Last, so that the six kinds that came before it still build the
            * way they always did.  It is here because a test asserting where a
            * label landed should be able to say which label, and comparing
            * rectangles to find out is how a test starts passing for the wrong
            * reason.
            */
            string content;

            /// What was actually asked for, whatever kind it turned out to be.
            Paint  paint;
        }

        Entry[] entries;

        void clear(Color color)
        {
            entries ~= Entry(Kind.clear, Rect.init, Point.init, Point.init,
                             color, 0, _transforms.current);
        }

        void fillRectangle(Rect rect, Paint paint)
        {
            record(Kind.fillRectangle, rect, paint, 0);
        }

        void drawRectangle(Rect rect, Paint paint, float strokeWidth = 1)
        {
            record(Kind.drawRectangle, rect, paint, strokeWidth);
        }

        void fillEllipse(Rect bounds, Paint paint)
        {
            record(Kind.fillEllipse, bounds, paint, 0);
        }

        void drawEllipse(Rect bounds, Paint paint, float strokeWidth = 1)
        {
            record(Kind.drawEllipse, bounds, paint, strokeWidth);
        }

        void drawLine(Point from, Point to, Paint paint, float strokeWidth = 1)
        {
            entries ~= Entry(Kind.line, Rect.init,
                             _transforms.current.transform(from),
                             _transforms.current.transform(to),
                             resolveColor(paint), strokeWidth, _transforms.current,
                             null, paint);
        }

       /*
        * Recorded as the box the text occupies, transformed like any other
        * rectangle -- so a test reads a label's placement the same way it
        * reads a swatch's, and never has to add the layout's size to an
        * origin for itself.
        */
        void drawText(TextLayout layout, Point origin, Paint paint)
        {
            immutable box = Rect(origin.x, origin.y, layout.size.width, layout.size.height);

            entries ~= Entry(Kind.text, mapBounds(_transforms.current, box),
                             Point.init, Point.init, resolveColor(paint), 0,
                             _transforms.current, layout.text, paint);
        }

        void pushTransform(Matrix transform) { _transforms.push(transform); }
        void popTransform() { _transforms.pop(); }
        @property Matrix currentTransform() { return _transforms.current; }

        /// How many pushes are outstanding -- what a test asks after a walk.
        @property size_t depth() { return _transforms.depth; }

    private:
        void record(Kind kind, Rect rect, Paint paint, float strokeWidth)
        {
            entries ~= Entry(kind, mapBounds(_transforms.current, rect),
                             Point.init, Point.init, resolveColor(paint), strokeWidth,
                             _transforms.current, null, paint);
        }

       /*
        * What a solid paint is made of, and transparent for anything a flat
        * colour cannot stand for.
        */
        static Color resolveColor(Paint paint)
        {
            if (auto solid = cast(SolidPaint) paint)
                return solid.color;

            return Color.transparent;
        }

       /*
        * The axis-aligned bounds of the transformed rectangle: four corners
        * mapped and boxed.  Exact while the transform is a translation or a
        * scale, which is all a layout produces; under a turn it is a box
        * around the shape, and a test asserting on it should know that.
        */
        static Rect mapBounds(Matrix m, Rect r)
        {
            immutable a = m.transform(Point(r.x, r.y));
            immutable b = m.transform(Point(r.right, r.y));
            immutable c = m.transform(Point(r.x, r.bottom));
            immutable d = m.transform(Point(r.right, r.bottom));

            immutable left   = min(min(a.x, b.x), min(c.x, d.x));
            immutable top    = min(min(a.y, b.y), min(c.y, d.y));
            immutable right  = max(max(a.x, b.x), max(c.x, d.x));
            immutable bottom = max(max(a.y, b.y), max(c.y, d.y));

            return Rect(left, top, right - left, bottom - top);
        }

        static float min(float a, float b) pure nothrow @nogc { return a < b ? a : b; }
        static float max(float a, float b) pure nothrow @nogc { return a > b ? a : b; }

        TransformStack _transforms;
    }

   /**
    * A TextService with metrics made up in advance: every character is seven
    * wide and every line sixteen high.
    *
    * A test about laying text out should be about laying text out.  Measured
    * against a real font it would be asserting on the machine it happens to be
    * running on -- on which shell font is installed, on the user's ClearType
    * settings, on the version of Segoe UI that shipped with this build of
    * Windows -- and would go red for reasons that have nothing to do with the
    * code under it.  The real backend is tested separately, against what it
    * can honestly promise.
    *
    * It counts what it hands out and what comes back, which is how a test says
    * that a control caches its layout instead of building one per pass, and
    * that it gives the old one back when it does rebuild.
    */
    class FakeTextService : TextService
    {
        enum charWidth  = 7.0f;
        enum lineHeight = 16.0f;

        /// How many layouts have been made, and how many disposed.
        int created;
        /// ditto
        int disposed;

        TextLayout createLayout(string text, TextFormat format, Size available)
        {
            ++created;

            immutable wraps = format.wrapping == TextWrapping.wrap
                           && available.width < float.infinity;

            size_t columns = text.length;
            size_t lines   = 1;

            if (wraps)
            {
                // At least one character per line whatever the room, or a
                // narrow enough box would ask for infinitely many lines.
                columns = cast(size_t)(available.width / charWidth);
                if (columns < 1)
                    columns = 1;

                if (text.length > columns)
                    lines = (text.length + columns - 1) / columns;
                else
                    columns = text.length;
            }

            // An empty run is not a run of no height: a line is as tall as the
            // font whether or not anything was typed on it, and a real backend
            // answers the same way.
            return new FakeTextLayout(this, text, format,
                                      Size(columns * charWidth, lines * lineHeight));
        }
    }

    /// ditto
    class FakeTextLayout : TextLayout
    {
        this(FakeTextService owner, string text, TextFormat format, Size size)
        {
            _owner = owner;
            _text = text;
            _format = format;
            _size = size;
        }

        @property Size size() { return _size; }
        @property string text() { return _text; }
        @property TextFormat format() { return _format; }

        void dispose()
        {
            if (_disposed)
                return;

            _disposed = true;
            ++_owner.disposed;
        }

        /// Whether dispose has been called -- what a leak test looks at.
        @property bool isDisposed() { return _disposed; }

    private:
        FakeTextService _owner;
        string          _text;
        TextFormat      _format;
        Size            _size;
        bool            _disposed;
    }
}

unittest
{
    // The fake's own arithmetic, so that a test built on it can be read
    // without working the numbers out again.
    auto service = new FakeTextService;

    auto plain = service.createLayout("hello", TextFormat.init, Size(500, 100));
    assert(plain.size == Size(5 * 7, 16));
    assert(plain.text == "hello");

    auto empty = service.createLayout("", TextFormat.init, Size(500, 100));
    assert(empty.size == Size(0, 16), "no width, but a line is still a line high");

    // Without wrapping the room is not a limit: what is asked for is what is
    // needed, and overflowing is the element's business.
    auto over = service.createLayout("hello", TextFormat.init, Size(10, 100));
    assert(over.size.width == 35);

    auto format = TextFormat.init;
    format.wrapping = TextWrapping.wrap;

    auto wrapped = service.createLayout("hello", format, Size(21, 100));
    assert(wrapped.size == Size(21, 32), "three to a line, so two lines");

    // The room decides the breaks only when there is a limit to break at.
    auto unbounded = service.createLayout("hello", format, Size(float.infinity, 100));
    assert(unbounded.size == Size(35, 16));

    assert(service.created == 5 && service.disposed == 0);
    plain.dispose();
    plain.dispose();
    assert(service.disposed == 1, "disposing twice is not disposing twice");
}

unittest
{
    // Text is recorded like every other primitive: in the target's own space,
    // with the transform already applied, and with enough of itself left to
    // say which run it was.
    auto service = new FakeTextService;
    auto layout = service.createLayout("Cherry", TextFormat.init, Size(500, 100));

    auto context = new RecordingContext;

    auto ink = new FakeSolidPaint(Color.black);

    context.pushTransform(Matrix.translation(30, 40));
    context.drawText(layout, Point(5, 5), ink);
    context.popTransform();

    assert(context.entries.length == 1);

    // Not immutable any more: an Entry carries a Paint now, and a class
    // reference does not convert to immutable on its own.
    auto entry = context.entries[0];
    assert(entry.kind == RecordingContext.Kind.text);
    assert(entry.content == "Cherry", "and a test can say which label it is reading");
    assert(entry.rect == Rect(35, 45, 6 * 7, 16),
           "the origin moved by the transform, and the box is the layout's own size");
    assert(entry.color == Color.black, "resolved from the paint, because it is a flat one");
    assert(entry.paint is ink, "and the paint itself is on the record too");
}
