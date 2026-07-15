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

// ----------------------------------------------------------------- GUIDs --

immutable IID IID_ID2D1Factory =
    IID(0x06152247, 0x6f50, 0x465a, [0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07]);

// ------------------------------------------------------------ interfaces --

interface ID2D1Resource : IUnknown
{
extern (Windows):
    void GetFactory(void** factory);
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
    HRESULT CreateGradientStopCollection(const(void)* gradientStops, uint gradientStopsCount,
                                         int colorInterpolationGamma, int extendMode,
                                         void** gradientStopCollection);
    HRESULT CreateLinearGradientBrush(const(void)* linearGradientBrushProperties,
                                      const(D2D1_BRUSH_PROPERTIES)* brushProperties,
                                      void* gradientStopCollection, void** linearGradientBrush);
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
                  float strokeWidth, void* strokeStyle);
    void DrawRectangle(const(D2D1_RECT_F)* rect, ID2D1Brush brush,
                       float strokeWidth, void* strokeStyle);
    void FillRectangle(const(D2D1_RECT_F)* rect, ID2D1Brush brush);
    void DrawRoundedRectangle(const(void)* roundedRect, ID2D1Brush brush,
                              float strokeWidth, void* strokeStyle);
    void FillRoundedRectangle(const(void)* roundedRect, ID2D1Brush brush);
    void DrawEllipse(const(D2D1_ELLIPSE)* ellipse, ID2D1Brush brush,
                     float strokeWidth, void* strokeStyle);
    void FillEllipse(const(D2D1_ELLIPSE)* ellipse, ID2D1Brush brush);
    void DrawGeometry(void* geometry, ID2D1Brush brush, float strokeWidth, void* strokeStyle);
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
    HRESULT CreateStrokeStyle(const(void)* strokeStyleProperties, const(float)* dashes, uint dashesCount, void** strokeStyle);
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
