module cherry.platform.win32.render;

version (Windows):

import core.sys.windows.windows;

import cherry.platform.render;
import cherry.platform.win32.d2d1;

/**
 * Direct2D implementation of WindowRenderer over an ID2D1HwndRenderTarget.
 *
 * D2D1_RENDER_TARGET_TYPE_DEFAULT gives hardware rendering with an
 * automatic software fallback, so the no-GPU case needs no extra code.
 * Device loss (D2DERR_RECREATE_TARGET from EndDraw) is handled by dropping
 * the target and recreating it on the next frame.
 */
final class D2DWindowRenderer : WindowRenderer
{
    this(void* hwnd)
    in {
        assert(hwnd !is null);
    }
    do {
        _hwnd = cast(HWND) hwnd;

        auto hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                    &IID_ID2D1Factory, null, cast(void**)&_factory);
        if (hr != S_OK)
            throw new Exception("Failed to create the Direct2D factory.");
    }

    void render(scope void delegate(DrawingContext) draw)
    {
        ensureTarget();

        _target.BeginDraw();
        _context.beginFrame();

        draw(_context);

        // A plain statement rather than a scope(exit): if draw threw, the
        // stack is legitimately unbalanced and asserting on the way out would
        // replace the real exception with a misleading one.  beginFrame is
        // what makes the next frame correct on that path; this only has to
        // catch element code that returned normally holding a push.
        assert(_context.transformDepth == 0,
               "every pushTransform must be matched by a popTransform before "
               ~ "the frame ends.");

        auto hr = _target.EndDraw(null, null);

        if (hr == D2DERR_RECREATE_TARGET)
        {
            // The device was lost; recreate everything on the next frame.
            releaseTarget();
            return;
        }

        if (hr != S_OK)
            throw new Exception("Direct2D EndDraw failed.");
    }

    void resize(int width, int height)
    {
        if (_target is null)
            return;

        auto size = D2D1_SIZE_U(width < 0 ? 0 : width, height < 0 ? 0 : height);
        _target.Resize(&size);
    }

    void dispose()
    {
        releaseTarget();

        if (_factory !is null)
        {
            _factory.Release();
            _factory = null;
        }
    }

private:
    void ensureTarget()
    {
        if (_target !is null)
            return;

        RECT client;
        GetClientRect(_hwnd, &client);

        auto targetProperties = D2D1_RENDER_TARGET_PROPERTIES(
            D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1_PIXEL_FORMAT(DXGI_FORMAT_UNKNOWN, D2D1_ALPHA_MODE_UNKNOWN),
            0, 0, 0, 0);
        auto hwndProperties = D2D1_HWND_RENDER_TARGET_PROPERTIES(
            _hwnd,
            D2D1_SIZE_U(client.right, client.bottom),
            D2D1_PRESENT_OPTIONS_NONE);

        auto hr = _factory.CreateHwndRenderTarget(&targetProperties, &hwndProperties, &_target);
        if (hr != S_OK)
            throw new Exception("Failed to create the Direct2D render target.");

        auto black = D2D1_COLOR_F(0, 0, 0, 1);
        hr = _target.CreateSolidColorBrush(&black, null, &_brush);
        if (hr != S_OK)
            throw new Exception("Failed to create the Direct2D brush.");

        _context = new D2DDrawingContext(_target, _brush);
    }

    void releaseTarget()
    {
        _context = null;

        if (_brush !is null)
        {
            _brush.Release();
            _brush = null;
        }

        if (_target !is null)
        {
            _target.Release();
            _target = null;
        }
    }

    HWND                  _hwnd;
    ID2D1Factory          _factory;
    ID2D1HwndRenderTarget _target;
    ID2D1SolidColorBrush  _brush;
    D2DDrawingContext     _context;
}

/**
 * DrawingContext over an ID2D1RenderTarget.  Solid colors are drawn through
 * one shared brush recolored per call -- the idiomatic cheap pattern.
 */
private final class D2DDrawingContext : DrawingContext
{
    this(ID2D1RenderTarget target, ID2D1SolidColorBrush brush)
    {
        _target = target;
        _brush = brush;
    }

    void clear(Color color)
    in {
        assert(_transforms.depth == 0,
               "Direct2D's Clear ignores the transform and fills the whole "
               ~ "target, so clearing from inside an element's coordinate "
               ~ "space would clear the window.  clear opens a frame.");
    }
    do {
        auto value = toColorF(color);
        _target.Clear(&value);
    }

    void fillRectangle(Rect rect, Color color)
    {
        auto area = toRectF(rect);
        _target.FillRectangle(&area, recolor(color));
    }

    void drawRectangle(Rect rect, Color color, float strokeWidth = 1)
    {
        auto area = toRectF(rect);
        _target.DrawRectangle(&area, recolor(color), strokeWidth, null);
    }

    void fillEllipse(Rect bounds, Color color)
    {
        auto ellipse = toEllipse(bounds);
        _target.FillEllipse(&ellipse, recolor(color));
    }

    void drawEllipse(Rect bounds, Color color, float strokeWidth = 1)
    {
        auto ellipse = toEllipse(bounds);
        _target.DrawEllipse(&ellipse, recolor(color), strokeWidth, null);
    }

    void drawLine(Point from, Point to, Color color, float strokeWidth = 1)
    {
        _target.DrawLine(D2D1_POINT_2F(from.x, from.y), D2D1_POINT_2F(to.x, to.y),
                         recolor(color), strokeWidth, null);
    }

    void pushTransform(Matrix transform)
    {
        _transforms.push(transform);
        applyTransform();
    }

    void popTransform()
    {
        _transforms.pop();
        applyTransform();
    }

    @property Matrix currentTransform()
    {
        return _transforms.current;
    }

   /*
    * Puts the context back where a frame begins: nothing pushed, the identity
    * in effect, whatever the frame before it left behind.
    *
    * The context is made once and lives across frames, so this is not
    * housekeeping -- without it a frame that an element threw out of would
    * leave the next one drawing inside a dead element's coordinate space,
    * with the whole window offset and nothing to say why.
    *
    * At the start of a frame rather than the end of one, because the frame
    * that leaves the stack unbalanced is exactly the frame whose ending code
    * does not run.
    */
    void beginFrame()
    {
        _transforms.reset();
        applyTransform();
    }

    /// What the renderer asserts on after handing the frame to element code.
    @property size_t transformDepth()
    {
        return _transforms.depth;
    }

private:
    void applyTransform()
    {
        auto value = toMatrix3x2(_transforms.current);
        _target.SetTransform(&value);
    }

    ID2D1Brush recolor(Color color)
    {
        auto value = toColorF(color);
        _brush.SetColor(&value);
        return _brush;
    }

    static D2D1_COLOR_F toColorF(Color color) pure nothrow @nogc
    {
        return D2D1_COLOR_F(color.r, color.g, color.b, color.a);
    }

    static D2D1_RECT_F toRectF(Rect rect) pure nothrow @nogc
    {
        return D2D1_RECT_F(rect.x, rect.y, rect.right, rect.bottom);
    }

    static D2D1_ELLIPSE toEllipse(Rect bounds) pure nothrow @nogc
    {
        return D2D1_ELLIPSE(
            D2D1_POINT_2F(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2),
            bounds.width / 2, bounds.height / 2);
    }

   /*
    * Field by field, although the two layouts are identical and render.d has
    * a static assert saying so.  Every other conversion in this file reads
    * the same way, the mapping between the two naming schemes is worth seeing
    * once, and the optimiser emits the same thing either way.  The
    * blittability is there to be relied on by a backend that needs it, not to
    * be spent here for nothing.
    */
    static D2D1_MATRIX_3X2_F toMatrix3x2(Matrix m) pure nothrow @nogc
    {
        return D2D1_MATRIX_3X2_F(m.m11, m.m12, m.m21, m.m22, m.dx, m.dy);
    }

    ID2D1RenderTarget    _target;
    ID2D1SolidColorBrush _brush;
    TransformStack       _transforms;
}
