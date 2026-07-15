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
        draw(_context);
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
    {
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

private:
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

    ID2D1RenderTarget    _target;
    ID2D1SolidColorBrush _brush;
}
