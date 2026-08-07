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
 * The surface elements draw onto during a frame.  Solid colors only for
 * now; brush objects, transforms, clips and text join the model as the
 * framework grows.
 */
interface DrawingContext
{
    /// Fills the whole target with the color.
    void clear(Color color);

    /// Fills a rectangle.
    void fillRectangle(Rect rect, Color color);

    /// Strokes a rectangle outline.
    void drawRectangle(Rect rect, Color color, float strokeWidth = 1);

    /// Fills the ellipse inscribed in the bounding rectangle.
    void fillEllipse(Rect bounds, Color color);

    /// Strokes the ellipse inscribed in the bounding rectangle.
    void drawEllipse(Rect bounds, Color color, float strokeWidth = 1);

    /// Strokes a line segment.
    void drawLine(Point from, Point to, Color color, float strokeWidth = 1);
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
