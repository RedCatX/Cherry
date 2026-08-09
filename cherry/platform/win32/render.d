module cherry.platform.win32.render;

version (Windows):

import core.sys.windows.windows;

import cherry.platform.render;
import cherry.platform.win32.d2d1;
import cherry.platform.win32.dwrite;
import cherry.platform.win32.text : DWriteTextLayout, dwriteFactory;

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

        createRenderingParams();

        _context = new D2DDrawingContext(_target, _brush, _displayParams, _idealParams);
    }

   /*
    * The rasterisation half of looking like the system.
    *
    * The monitor's own parameters are the user's ClearType settings for the
    * screen this window is on -- gamma, contrast, how much colour fringing to
    * allow, which way round the subpixels are.  They come from the tuner in
    * Control Panel, and text drawn without them is text that does not match
    * anything else on the desktop however right the font is.
    *
    * Those are what TextRendering.ideal draws with.  For display everything is
    * kept except the rendering mode, which becomes GDI_CLASSIC: this user's
    * ClearType, rasterised the way a Win32 control rasterises it.  Overriding
    * the mode alone is the point -- a fixed set of parameters would be somebody
    * else's screen.
    *
    * Failure is not fatal.  Direct2D has defaults, and text drawn with them is
    * merely not tuned; a window that would not open because the ClearType
    * settings could not be read would be a worse answer.
    *
    * Not re-made when the window is dragged to another monitor.  The settings
    * are per-screen, so the day that matters is the day WM_DPICHANGED is
    * handled, and both belong to the same piece of work.
    */
    void createRenderingParams()
    {
        auto factory = dwriteFactory();

        auto hr = factory.CreateMonitorRenderingParams(
            MonitorFromWindow(_hwnd, MONITOR_DEFAULTTONEAREST), &_idealParams);

        if (hr != S_OK && factory.CreateRenderingParams(&_idealParams) != S_OK)
            return;

        factory.CreateCustomRenderingParams(_idealParams.GetGamma(),
                                            _idealParams.GetEnhancedContrast(),
                                            _idealParams.GetClearTypeLevel(),
                                            _idealParams.GetPixelGeometry(),
                                            DWRITE_RENDERING_MODE_GDI_CLASSIC,
                                            &_displayParams);
    }

    void releaseTarget()
    {
        // Before the context goes: every gradient it cached belongs to this
        // target and dies with it.  A cache that outlived the device would hand
        // out brushes built against a device that no longer exists.
        if (_context !is null)
            _context.releaseGradients();

        _context = null;

        if (_displayParams !is null)
        {
            _displayParams.Release();
            _displayParams = null;
        }

        if (_idealParams !is null)
        {
            _idealParams.Release();
            _idealParams = null;
        }

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

    HWND                   _hwnd;
    ID2D1Factory           _factory;
    ID2D1HwndRenderTarget  _target;
    ID2D1SolidColorBrush   _brush;
    IDWriteRenderingParams _displayParams;
    IDWriteRenderingParams _idealParams;
    D2DDrawingContext      _context;
}

/**
 * DrawingContext over an ID2D1RenderTarget.  Solid colors are drawn through
 * one shared brush recolored per call -- the idiomatic cheap pattern.
 */
private final class D2DDrawingContext : DrawingContext
{
    this(ID2D1RenderTarget target, ID2D1SolidColorBrush brush,
         IDWriteRenderingParams displayParams, IDWriteRenderingParams idealParams)
    {
        _target = target;
        _brush = brush;
        _displayParams = displayParams;
        _idealParams = idealParams;
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

    void fillRectangle(Rect rect, Paint paint)
    {
        if (auto brush = deviceBrush(paint, rect))
        {
            auto area = toRectF(rect);
            _target.FillRectangle(&area, brush);
        }
    }

    void drawRectangle(Rect rect, Paint paint, float strokeWidth = 1)
    {
        if (auto brush = deviceBrush(paint, rect))
        {
            auto area = toRectF(rect);
            _target.DrawRectangle(&area, brush, strokeWidth, null);
        }
    }

    void fillRoundedRectangle(Rect rect, float radiusX, float radiusY, Paint paint)
    {
        if (auto brush = deviceBrush(paint, rect))
        {
            auto rounded = toRoundedRect(rect, radiusX, radiusY);
            _target.FillRoundedRectangle(&rounded, brush);
        }
    }

    void drawRoundedRectangle(Rect rect, float radiusX, float radiusY, Paint paint,
                              float strokeWidth = 1)
    {
        if (auto brush = deviceBrush(paint, rect))
        {
            auto rounded = toRoundedRect(rect, radiusX, radiusY);
            _target.DrawRoundedRectangle(&rounded, brush, strokeWidth, null);
        }
    }

    void fillEllipse(Rect bounds, Paint paint)
    {
        if (auto brush = deviceBrush(paint, bounds))
        {
            auto ellipse = toEllipse(bounds);
            _target.FillEllipse(&ellipse, brush);
        }
    }

    void drawEllipse(Rect bounds, Paint paint, float strokeWidth = 1)
    {
        if (auto brush = deviceBrush(paint, bounds))
        {
            auto ellipse = toEllipse(bounds);
            _target.DrawEllipse(&ellipse, brush, strokeWidth, null);
        }
    }

    void drawLine(Point from, Point to, Paint paint, float strokeWidth = 1)
    {
        // A gradient reads its ends as fractions of what is being filled, and
        // for a line that is the box the segment spans.  A line running the
        // other way therefore gets the ramp the other way round, which is what
        // anybody drawing one would expect.
        immutable span = Rect(from.x < to.x ? from.x : to.x,
                              from.y < to.y ? from.y : to.y,
                              from.x < to.x ? to.x - from.x : from.x - to.x,
                              from.y < to.y ? to.y - from.y : from.y - to.y);

        if (auto brush = deviceBrush(paint, span))
            _target.DrawLine(D2D1_POINT_2F(from.x, from.y), D2D1_POINT_2F(to.x, to.y),
                             brush, strokeWidth, null);
    }

   /**
    * Draws a layout DirectWrite already built, through the rasterisation
    * parameters its rendering mode asks for.
    *
    * The layout has to be one of ours, and a foreign one is refused rather
    * than skipped: it means the caller measured with one service and drew with
    * another, and text that silently fails to appear is a long afternoon.
    */
    void drawText(TextLayout layout, Point origin, Paint paint)
    {
        auto native = cast(DWriteTextLayout) layout;
        if (native is null || native.native is null)
            throw new Exception("Direct2D can only draw a layout made by the "
                                ~ "DirectWrite text service, and not a disposed one.");

        immutable box = Rect(origin.x, origin.y, layout.size.width, layout.size.height);

        auto brush = deviceBrush(paint, box);
        if (brush is null)
            return;

        applyRenderingParams(layout.format.rendering);

        _target.DrawTextLayout(D2D1_POINT_2F(origin.x, origin.y),
                               cast(void*) native.native, brush,
                               D2D1_DRAW_TEXT_OPTIONS_NONE);
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

        // The parameters themselves stay on the target across frames; what is
        // forgotten here is only which ones this context believes are in
        // effect, so the first run of text in a frame sets them rather than
        // trusting a memory of the last one.
        _appliedRendering = -1;
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

   /*
    * The Direct2D brush for a paint, ready to fill the given geometry.
    *
    * A solid paint gets no cache at all -- the one shared brush is recoloured,
    * exactly as before there were paints.  That is the path almost every fill
    * takes, and it stays as cheap as it was.
    *
    * A paint of a kind this backend has never heard of gets null, and the
    * caller draws nothing.  Refusing quietly is right here: the drawing model
    * may grow a kind before this backend does, and a window that threw would
    * take down the frame over a fill it could have skipped.
    */
    ID2D1Brush deviceBrush(Paint paint, Rect bounds)
    {
        if (auto solid = cast(SolidPaint) paint)
            return recolor(solid.color);

        if (auto gradient = cast(GradientPaint) paint)
            return linearGradientBrush(gradient, bounds);

        return null;
    }

   /*
    * The cached gradient brush for a paint, rebuilt when the paint says it has
    * changed and re-aimed at the geometry on every call.
    *
    * Two things happen here and they are worth telling apart.  The stop
    * collection and the brush are expensive and are built once per paint, kept
    * until its revision moves or the target goes.  The start and end points are
    * cheap and are set on every fill, because they are fractions of what is
    * being filled and the same brush paints a button and a window differently.
    *
    * The cache holds its paints alive until the target is released, so a brush
    * used once and dropped keeps a device resource for the life of the window.
    * That is worth fixing when there is something to measure; it is bounded by
    * how many distinct gradients an application makes, which is small.
    */
    ID2D1Brush linearGradientBrush(GradientPaint paint, Rect bounds)
    {
        auto key = cast(Object) paint;
        auto cached = key in _gradients;

        if (cached is null || cached.revision != paint.revision)
        {
            if (cached !is null)
                cached.brush.Release();

            auto made = createGradientBrush(paint);
            if (made is null)
            {
                if (cached !is null)
                    _gradients.remove(key);

                return null;
            }

            _gradients[key] = CachedGradient(made, paint.revision);
            cached = key in _gradients;
        }

        cached.brush.SetStartPoint(D2D1_POINT_2F(bounds.x + paint.start.x * bounds.width,
                                                 bounds.y + paint.start.y * bounds.height));
        cached.brush.SetEndPoint(D2D1_POINT_2F(bounds.x + paint.end.x * bounds.width,
                                               bounds.y + paint.end.y * bounds.height));

        return cached.brush;
    }

   /*
    * Builds the stop collection and the brush, or null if the paint has no
    * colours to ramp between -- Direct2D refuses an empty collection, and a
    * gradient of nothing has nothing to draw anyway.
    *
    * The placeholder ends are replaced before every fill; what matters at
    * creation is only that they are valid numbers.
    */
    ID2D1LinearGradientBrush createGradientBrush(GradientPaint paint)
    {
        auto stops = paint.stops;
        if (stops.length == 0)
            return null;

        auto native = new D2D1_GRADIENT_STOP[stops.length];
        foreach (i, stop; stops)
            native[i] = D2D1_GRADIENT_STOP(stop.offset, toColorF(stop.color));

        ID2D1GradientStopCollection collection;
        auto hr = _target.CreateGradientStopCollection(native.ptr, cast(uint) native.length,
                                                       D2D1_GAMMA_2_2, toExtendMode(paint.spread),
                                                       &collection);
        if (hr != S_OK)
            return null;

        scope (exit) collection.Release();

        auto properties = D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES(D2D1_POINT_2F(0, 0),
                                                                D2D1_POINT_2F(0, 1));

        ID2D1LinearGradientBrush brush;
        hr = _target.CreateLinearGradientBrush(&properties, null, collection, &brush);

        return hr == S_OK ? brush : null;
    }

    static int toExtendMode(GradientSpread spread) pure nothrow @nogc
    {
        final switch (spread)
        {
            case GradientSpread.pad:     return D2D1_EXTEND_MODE_CLAMP;
            case GradientSpread.reflect: return D2D1_EXTEND_MODE_MIRROR;
            case GradientSpread.repeat:  return D2D1_EXTEND_MODE_WRAP;
        }
    }

    /// Lets the renderer drop every device resource when the target goes.
    void releaseGradients()
    {
        foreach (entry; _gradients)
            entry.brush.Release();

        _gradients = null;
    }

   /*
    * Puts the rasterisation parameters for a rendering mode in effect, and
    * only when they are not already.
    *
    * They are state on the target rather than an argument to the draw, so a
    * frame mixing the two modes has to switch between runs -- and a frame
    * using one mode throughout, which is every frame anybody will write for a
    * while, pays for one call.
    *
    * Null parameters mean the settings could not be read; Direct2D's own
    * defaults then stand, which is the right thing to leave alone.
    */
    void applyRenderingParams(TextRendering rendering)
    {
        if (_appliedRendering == cast(int) rendering)
            return;

        auto params = rendering == TextRendering.display ? _displayParams : _idealParams;
        if (params is null)
            return;

        _target.SetTextRenderingParams(cast(void*) params);
        _appliedRendering = cast(int) rendering;
    }

    static D2D1_COLOR_F toColorF(Color color) pure nothrow @nogc
    {
        return D2D1_COLOR_F(color.r, color.g, color.b, color.a);
    }

    static D2D1_RECT_F toRectF(Rect rect) pure nothrow @nogc
    {
        return D2D1_RECT_F(rect.x, rect.y, rect.right, rect.bottom);
    }

    static D2D1_ROUNDED_RECT toRoundedRect(Rect rect, float radiusX, float radiusY) pure nothrow @nogc
    {
        return D2D1_ROUNDED_RECT(toRectF(rect), radiusX, radiusY);
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

    /// One gradient's device resource and the revision it was built from.
    static struct CachedGradient
    {
        ID2D1LinearGradientBrush brush;
        ulong                    revision;
    }

    ID2D1RenderTarget      _target;
    ID2D1SolidColorBrush   _brush;
    IDWriteRenderingParams _displayParams;
    IDWriteRenderingParams _idealParams;
    CachedGradient[Object] _gradients;
    TransformStack         _transforms;

    // Which mode's parameters the target is carrying, or -1 for "not yet
    // said".  An int rather than the enum, because "none of them" is a state
    // the enum has no business naming.
    int _appliedRendering = -1;
}
