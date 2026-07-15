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
