module cherry.platform.win32.d2d1;

/*
 * Minimal hand-written Direct2D COM bindings -- only what the renderer
 * needs.  druntime does not ship d2d1 headers, so the vtable layouts below
 * are transcribed from d2d1.h; METHOD ORDER IS ABI -- do not reorder.
 *
 * Two ABI rules observed here:
 *  - C++ instance methods returning aggregates (GetSize, GetPixelFormat,
 *    GetColor, ...) return them through a hidden pointer on Win64 even when
 *    the struct is small; such methods are declared with an explicit
 *    out-pointer parameter, matching the C interface in d2d1.h.
 *  - Small structs passed by value (D2D1_POINT_2F in DrawLine) follow the
 *    regular Win64 by-value rules, which DMD implements.
 *
 * Interfaces that the renderer never touches are declared as void* in
 * parameter lists; only the vtable slot order of the interfaces we DO call
 * matters.
 */

version (Windows):

import core.sys.windows.windows;

pragma(lib, "d2d1");

// ---------------------------------------------------------------- enums --

enum D2D1_FACTORY_TYPE_SINGLE_THREADED = 0;

enum D2D1_RENDER_TARGET_TYPE_DEFAULT  = 0;
enum D2D1_RENDER_TARGET_TYPE_SOFTWARE = 1;
enum D2D1_RENDER_TARGET_TYPE_HARDWARE = 2;

enum D2D1_PRESENT_OPTIONS_NONE = 0;

enum DXGI_FORMAT_UNKNOWN     = 0;
enum D2D1_ALPHA_MODE_UNKNOWN = 0;

// Which space the colours between two stops are mixed in.  2.2 is the one
// Direct2D means by "the usual"; 1.0 is linear and is what a physically
// correct blend wants.
enum D2D1_GAMMA_2_2 = 0;
enum D2D1_GAMMA_1_0 = 1;

enum D2D1_EXTEND_MODE_CLAMP  = 0;
enum D2D1_EXTEND_MODE_WRAP   = 1;
enum D2D1_EXTEND_MODE_MIRROR = 2;

enum D2D1_CAP_STYLE_FLAT     = 0;
enum D2D1_CAP_STYLE_SQUARE   = 1;
enum D2D1_CAP_STYLE_ROUND    = 2;
enum D2D1_CAP_STYLE_TRIANGLE = 3;

enum D2D1_LINE_JOIN_MITER          = 0;
enum D2D1_LINE_JOIN_BEVEL          = 1;
enum D2D1_LINE_JOIN_ROUND          = 2;
enum D2D1_LINE_JOIN_MITER_OR_BEVEL = 3;

enum D2D1_DASH_STYLE_SOLID        = 0;
enum D2D1_DASH_STYLE_DASH         = 1;
enum D2D1_DASH_STYLE_DOT          = 2;
enum D2D1_DASH_STYLE_DASH_DOT     = 3;
enum D2D1_DASH_STYLE_DASH_DOT_DOT = 4;
enum D2D1_DASH_STYLE_CUSTOM       = 5;

enum HRESULT D2DERR_RECREATE_TARGET = 0x8899000C;

alias D2D1_TAG = ulong;

// --------------------------------------------------------------- structs --

struct D2D1_COLOR_F
{
    float r, g, b, a;
}

struct D2D1_POINT_2F
{
    float x, y;
}

struct D2D1_SIZE_F
{
    float width, height;
}

struct D2D1_SIZE_U
{
    uint width, height;
}

struct D2D1_RECT_F
{
    float left, top, right, bottom;
}

struct D2D1_ELLIPSE
{
    D2D1_POINT_2F point;
    float radiusX, radiusY;
}

struct D2D1_ROUNDED_RECT
{
    D2D1_RECT_F rect;
    float radiusX, radiusY;
}

struct D2D1_MATRIX_3X2_F
{
    float _11, _12, _21, _22, _31, _32;
}

struct D2D1_PIXEL_FORMAT
{
    int format;     // DXGI_FORMAT
    int alphaMode;  // D2D1_ALPHA_MODE
}

struct D2D1_RENDER_TARGET_PROPERTIES
{
    int type;       // D2D1_RENDER_TARGET_TYPE
    D2D1_PIXEL_FORMAT pixelFormat;
    float dpiX = 0;
    float dpiY = 0;
    int usage;      // D2D1_RENDER_TARGET_USAGE
    int minLevel;   // D2D1_FEATURE_LEVEL
}

struct D2D1_HWND_RENDER_TARGET_PROPERTIES
{
    HWND hwnd;
    D2D1_SIZE_U pixelSize;
    int presentOptions; // D2D1_PRESENT_OPTIONS
}

struct D2D1_BRUSH_PROPERTIES
{
    float opacity;
    D2D1_MATRIX_3X2_F transform;
}

struct D2D1_GRADIENT_STOP
{
    float position;
    D2D1_COLOR_F color;
}

struct D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES
{
    D2D1_POINT_2F startPoint;
    D2D1_POINT_2F endPoint;
}

struct D2D1_STROKE_STYLE_PROPERTIES
{
    int   startCap;     // D2D1_CAP_STYLE
    int   endCap;       // D2D1_CAP_STYLE
    int   dashCap;      // D2D1_CAP_STYLE
    int   lineJoin;     // D2D1_LINE_JOIN
    float miterLimit = 10;
    int   dashStyle;    // D2D1_DASH_STYLE
    float dashOffset = 0;
}

// ----------------------------------------------------------------- GUIDs --

immutable IID IID_ID2D1Factory =
    IID(0x06152247, 0x6f50, 0x465a, [0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07]);

// ------------------------------------------------------------ interfaces --

interface ID2D1Resource : IUnknown
{
extern (Windows):
    void GetFactory(void** factory);
}

/**
 * The shape of a stroke -- its ends, its corners and its dashes -- with no
 * colour and no width, which are given to each drawing call instead.
 *
 * A factory resource and not a device one, so it outlives a lost render target;
 * only the cache holding it is tied to a target's lifetime.  None of its own
 * methods are ever called, so none are declared: what the renderer needs is a
 * pointer to hand back to a draw.
 */
interface ID2D1StrokeStyle : ID2D1Resource
{
}

interface ID2D1Brush : ID2D1Resource
{
extern (Windows):
    void SetOpacity(float opacity);
    void SetTransform(const(D2D1_MATRIX_3X2_F)* transform);
    float GetOpacity();
    void GetTransform(D2D1_MATRIX_3X2_F* transform);
}

interface ID2D1SolidColorBrush : ID2D1Brush
{
extern (Windows):
    void SetColor(const(D2D1_COLOR_F)* color);
    void GetColor(D2D1_COLOR_F* result);   // hidden-pointer aggregate return
}

/**
 * The colours of a gradient, kept apart from the brushes that use them so that
 * a ramp can be shared -- and, more to the point here, so that it is built once
 * per brush rather than once per fill.
 */
interface ID2D1GradientStopCollection : ID2D1Resource
{
extern (Windows):
    uint GetGradientStopCount();
    void GetGradientStops(D2D1_GRADIENT_STOP* gradientStops, uint gradientStopsCount);
    int  GetColorInterpolationGamma();
    int  GetExtendMode();
}

interface ID2D1LinearGradientBrush : ID2D1Brush
{
extern (Windows):
    void SetStartPoint(D2D1_POINT_2F startPoint);
    void SetEndPoint(D2D1_POINT_2F endPoint);
    // Both of these return D2D1_POINT_2F by value in C++, which on Win64 means
    // a hidden out-pointer -- the rule the banner at the top of this file is
    // about.  Declared with the pointer and never called: the framework sets
    // the ends on every fill and has no reason to read them back.
    void GetStartPoint(D2D1_POINT_2F* result);
    void GetEndPoint(D2D1_POINT_2F* result);
    void GetGradientStopCollection(ID2D1GradientStopCollection* gradientStopCollection);
}

interface ID2D1RenderTarget : ID2D1Resource
{
extern (Windows):
    HRESULT CreateBitmap(D2D1_SIZE_U size, const(void)* srcData, uint pitch,
                         const(void)* bitmapProperties, void** bitmap);
    HRESULT CreateBitmapFromWicBitmap(void* wicBitmapSource,
                                      const(void)* bitmapProperties, void** bitmap);
    HRESULT CreateSharedBitmap(const(IID)* riid, void* data,
                               const(void)* bitmapProperties, void** bitmap);
    HRESULT CreateBitmapBrush(void* bitmap, const(void)* bitmapBrushProperties,
                              const(D2D1_BRUSH_PROPERTIES)* brushProperties, void** bitmapBrush);
    HRESULT CreateSolidColorBrush(const(D2D1_COLOR_F)* color,
                                  const(D2D1_BRUSH_PROPERTIES)* brushProperties,
                                  ID2D1SolidColorBrush* brush);
    HRESULT CreateGradientStopCollection(const(D2D1_GRADIENT_STOP)* gradientStops, uint gradientStopsCount,
                                         int colorInterpolationGamma, int extendMode,
                                         ID2D1GradientStopCollection* gradientStopCollection);
    HRESULT CreateLinearGradientBrush(const(D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES)* linearGradientBrushProperties,
                                      const(D2D1_BRUSH_PROPERTIES)* brushProperties,
                                      ID2D1GradientStopCollection gradientStopCollection,
                                      ID2D1LinearGradientBrush* linearGradientBrush);
    HRESULT CreateRadialGradientBrush(const(void)* radialGradientBrushProperties,
                                      const(D2D1_BRUSH_PROPERTIES)* brushProperties,
                                      void* gradientStopCollection, void** radialGradientBrush);
    HRESULT CreateCompatibleRenderTarget(const(D2D1_SIZE_F)* desiredSize,
                                         const(D2D1_SIZE_U)* desiredPixelSize,
                                         const(D2D1_PIXEL_FORMAT)* desiredFormat,
                                         int options, void** bitmapRenderTarget);
    HRESULT CreateLayer(const(D2D1_SIZE_F)* size, void** layer);
    HRESULT CreateMesh(void** mesh);
    void DrawLine(D2D1_POINT_2F point0, D2D1_POINT_2F point1, ID2D1Brush brush,
                  float strokeWidth, ID2D1StrokeStyle strokeStyle);
    void DrawRectangle(const(D2D1_RECT_F)* rect, ID2D1Brush brush,
                       float strokeWidth, ID2D1StrokeStyle strokeStyle);
    void FillRectangle(const(D2D1_RECT_F)* rect, ID2D1Brush brush);
    void DrawRoundedRectangle(const(D2D1_ROUNDED_RECT)* roundedRect, ID2D1Brush brush,
                              float strokeWidth, ID2D1StrokeStyle strokeStyle);
    void FillRoundedRectangle(const(D2D1_ROUNDED_RECT)* roundedRect, ID2D1Brush brush);
    void DrawEllipse(const(D2D1_ELLIPSE)* ellipse, ID2D1Brush brush,
                     float strokeWidth, ID2D1StrokeStyle strokeStyle);
    void FillEllipse(const(D2D1_ELLIPSE)* ellipse, ID2D1Brush brush);
    void DrawGeometry(void* geometry, ID2D1Brush brush, float strokeWidth, ID2D1StrokeStyle strokeStyle);
    void FillGeometry(void* geometry, ID2D1Brush brush, ID2D1Brush opacityBrush);
    void FillMesh(void* mesh, ID2D1Brush brush);
    void FillOpacityMask(void* opacityMask, ID2D1Brush brush, int content,
                         const(D2D1_RECT_F)* destinationRectangle,
                         const(D2D1_RECT_F)* sourceRectangle);
    void DrawBitmap(void* bitmap, const(D2D1_RECT_F)* destinationRectangle, float opacity,
                    int interpolationMode, const(D2D1_RECT_F)* sourceRectangle);
    void DrawText(const(wchar)* string_, uint stringLength, void* textFormat,
                  const(D2D1_RECT_F)* layoutRect, ID2D1Brush defaultForegroundBrush,
                  int options, int measuringMode);
    void DrawTextLayout(D2D1_POINT_2F origin, void* textLayout,
                        ID2D1Brush defaultForegroundBrush, int options);
    void DrawGlyphRun(D2D1_POINT_2F baselineOrigin, const(void)* glyphRun,
                      ID2D1Brush foregroundBrush, int measuringMode);
    void SetTransform(const(D2D1_MATRIX_3X2_F)* transform);
    void GetTransform(D2D1_MATRIX_3X2_F* transform);
    void SetAntialiasMode(int antialiasMode);
    int GetAntialiasMode();
    void SetTextAntialiasMode(int textAntialiasMode);
    int GetTextAntialiasMode();
    void SetTextRenderingParams(void* textRenderingParams);
    void GetTextRenderingParams(void** textRenderingParams);
    void SetTags(D2D1_TAG tag1, D2D1_TAG tag2);
    void GetTags(D2D1_TAG* tag1, D2D1_TAG* tag2);
    void PushLayer(const(void)* layerParameters, void* layer);
    void PopLayer();
    HRESULT Flush(D2D1_TAG* tag1, D2D1_TAG* tag2);
    void SaveDrawingState(void* drawingStateBlock);
    void RestoreDrawingState(void* drawingStateBlock);
    void PushAxisAlignedClip(const(D2D1_RECT_F)* clipRect, int antialiasMode);
    void PopAxisAlignedClip();
    void Clear(const(D2D1_COLOR_F)* clearColor);
    void BeginDraw();
    HRESULT EndDraw(D2D1_TAG* tag1, D2D1_TAG* tag2);
    void GetPixelFormat(D2D1_PIXEL_FORMAT* result);   // hidden-pointer aggregate return
    void SetDpi(float dpiX, float dpiY);
    void GetDpi(float* dpiX, float* dpiY);
    void GetSize(D2D1_SIZE_F* result);                // hidden-pointer aggregate return
    void GetPixelSize(D2D1_SIZE_U* result);           // hidden-pointer aggregate return
    uint GetMaximumBitmapSize();
    BOOL IsSupported(const(D2D1_RENDER_TARGET_PROPERTIES)* renderTargetProperties);
}

interface ID2D1HwndRenderTarget : ID2D1RenderTarget
{
extern (Windows):
    int CheckWindowState();
    HRESULT Resize(const(D2D1_SIZE_U)* pixelSize);
    HWND GetHwnd();
}

interface ID2D1Factory : IUnknown
{
extern (Windows):
    HRESULT ReloadSystemMetrics();
    void GetDesktopDpi(float* dpiX, float* dpiY);
    HRESULT CreateRectangleGeometry(const(D2D1_RECT_F)* rectangle, void** rectangleGeometry);
    HRESULT CreateRoundedRectangleGeometry(const(void)* roundedRectangle, void** roundedRectangleGeometry);
    HRESULT CreateEllipseGeometry(const(D2D1_ELLIPSE)* ellipse, void** ellipseGeometry);
    HRESULT CreateGeometryGroup(int fillMode, void** geometries, uint geometriesCount, void** geometryGroup);
    HRESULT CreateTransformedGeometry(void* sourceGeometry, const(D2D1_MATRIX_3X2_F)* transform, void** transformedGeometry);
    HRESULT CreatePathGeometry(void** pathGeometry);
    HRESULT CreateStrokeStyle(const(D2D1_STROKE_STYLE_PROPERTIES)* strokeStyleProperties,
                              const(float)* dashes, uint dashesCount,
                              ID2D1StrokeStyle* strokeStyle);
    HRESULT CreateDrawingStateBlock(const(void)* drawingStateDescription, void* textRenderingParams, void** drawingStateBlock);
    HRESULT CreateWicBitmapRenderTarget(void* target, const(D2D1_RENDER_TARGET_PROPERTIES)* renderTargetProperties, void** renderTarget);
    HRESULT CreateHwndRenderTarget(const(D2D1_RENDER_TARGET_PROPERTIES)* renderTargetProperties,
                                   const(D2D1_HWND_RENDER_TARGET_PROPERTIES)* hwndRenderTargetProperties,
                                   ID2D1HwndRenderTarget* hwndRenderTarget);
    HRESULT CreateDxgiSurfaceRenderTarget(void* dxgiSurface, const(D2D1_RENDER_TARGET_PROPERTIES)* renderTargetProperties, void** renderTarget);
    HRESULT CreateDCRenderTarget(const(D2D1_RENDER_TARGET_PROPERTIES)* renderTargetProperties, void** dcRenderTarget);
}

// ------------------------------------------------------------- functions --

extern (Windows) HRESULT D2D1CreateFactory(int factoryType, const(IID)* riid,
                                           const(void)* factoryOptions, void** factory) nothrow;
