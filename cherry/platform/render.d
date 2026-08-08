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
        enum Kind { clear, fillRectangle, drawRectangle, fillEllipse, drawEllipse, line }

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
            Color  color;
            float  strokeWidth = 0;
            Matrix transform;
        }

        Entry[] entries;

        void clear(Color color)
        {
            entries ~= Entry(Kind.clear, Rect.init, Point.init, Point.init,
                             color, 0, _transforms.current);
        }

        void fillRectangle(Rect rect, Color color)
        {
            record(Kind.fillRectangle, rect, color, 0);
        }

        void drawRectangle(Rect rect, Color color, float strokeWidth = 1)
        {
            record(Kind.drawRectangle, rect, color, strokeWidth);
        }

        void fillEllipse(Rect bounds, Color color)
        {
            record(Kind.fillEllipse, bounds, color, 0);
        }

        void drawEllipse(Rect bounds, Color color, float strokeWidth = 1)
        {
            record(Kind.drawEllipse, bounds, color, strokeWidth);
        }

        void drawLine(Point from, Point to, Color color, float strokeWidth = 1)
        {
            entries ~= Entry(Kind.line, Rect.init,
                             _transforms.current.transform(from),
                             _transforms.current.transform(to),
                             color, strokeWidth, _transforms.current);
        }

        void pushTransform(Matrix transform) { _transforms.push(transform); }
        void popTransform() { _transforms.pop(); }
        @property Matrix currentTransform() { return _transforms.current; }

        /// How many pushes are outstanding -- what a test asks after a walk.
        @property size_t depth() { return _transforms.depth; }

    private:
        void record(Kind kind, Rect rect, Color color, float strokeWidth)
        {
            entries ~= Entry(kind, mapBounds(_transforms.current, rect),
                             Point.init, Point.init, color, strokeWidth,
                             _transforms.current);
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
}
