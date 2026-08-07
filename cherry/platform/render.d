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
