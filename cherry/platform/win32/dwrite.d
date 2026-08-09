module cherry.platform.win32.dwrite;

/*
 * Minimal hand-written DirectWrite COM bindings -- only what the text service
 * needs.  druntime does not ship dwrite headers, so the vtable layouts below
 * are transcribed from dwrite.h; METHOD ORDER IS ABI -- do not reorder.
 *
 * The same two ABI rules d2d1.d observes apply here, and neither bites: no
 * method of these four interfaces returns an aggregate by value, and the one
 * struct passed by value (DWRITE_TEXT_RANGE, eight bytes) follows the regular
 * Win64 rules that DMD implements.
 *
 * Interfaces that the text service never touches are declared as void* in
 * parameter lists, as in d2d1.d.  What must NOT be simplified is the number of
 * parameters -- see the banner above IDWriteTextLayout.
 */

version (Windows):

import core.sys.windows.windows;

pragma(lib, "dwrite");

// ---------------------------------------------------------------- enums --

enum DWRITE_FACTORY_TYPE_SHARED   = 0;
enum DWRITE_FACTORY_TYPE_ISOLATED = 1;

// The numbers are the weights themselves, which is why they are worth having
// here rather than as a bare ordinal: 400 is regular and 700 is bold in every
// font format there has ever been.
enum DWRITE_FONT_WEIGHT_THIN        = 100;
enum DWRITE_FONT_WEIGHT_EXTRA_LIGHT = 200;
enum DWRITE_FONT_WEIGHT_LIGHT       = 300;
enum DWRITE_FONT_WEIGHT_SEMI_LIGHT  = 350;
enum DWRITE_FONT_WEIGHT_NORMAL      = 400;
enum DWRITE_FONT_WEIGHT_MEDIUM      = 500;
enum DWRITE_FONT_WEIGHT_SEMI_BOLD   = 600;
enum DWRITE_FONT_WEIGHT_BOLD        = 700;
enum DWRITE_FONT_WEIGHT_EXTRA_BOLD  = 800;
enum DWRITE_FONT_WEIGHT_BLACK       = 900;

enum DWRITE_FONT_STYLE_NORMAL  = 0;
enum DWRITE_FONT_STYLE_OBLIQUE = 1;
enum DWRITE_FONT_STYLE_ITALIC  = 2;

enum DWRITE_FONT_STRETCH_NORMAL = 5;

enum DWRITE_WORD_WRAPPING_WRAP    = 0;
enum DWRITE_WORD_WRAPPING_NO_WRAP = 1;

enum DWRITE_TEXT_ALIGNMENT_LEADING = 0;

enum DWRITE_PIXEL_GEOMETRY_FLAT = 0;
enum DWRITE_PIXEL_GEOMETRY_RGB  = 1;
enum DWRITE_PIXEL_GEOMETRY_BGR  = 2;

enum DWRITE_RENDERING_MODE_DEFAULT           = 0;
enum DWRITE_RENDERING_MODE_ALIASED           = 1;
enum DWRITE_RENDERING_MODE_GDI_CLASSIC       = 2;
enum DWRITE_RENDERING_MODE_GDI_NATURAL       = 3;
enum DWRITE_RENDERING_MODE_NATURAL           = 4;
enum DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC = 5;
enum DWRITE_RENDERING_MODE_OUTLINE           = 6;

// Direct2D's, not DirectWrite's, but it is only ever passed to DrawTextLayout
// alongside these -- and d2d1.d has no other text in it.
enum D2D1_DRAW_TEXT_OPTIONS_NONE    = 0;
enum D2D1_DRAW_TEXT_OPTIONS_NO_SNAP = 1;
enum D2D1_DRAW_TEXT_OPTIONS_CLIP    = 2;

// --------------------------------------------------------------- structs --

struct DWRITE_TEXT_METRICS
{
    float left;
    float top;
    float width;
    float widthIncludingTrailingWhitespace;
    float height;
    float layoutWidth;
    float layoutHeight;
    uint  maxBidiReorderingDepth;
    uint  lineCount;
}

struct DWRITE_LINE_METRICS
{
    uint  length;
    uint  trailingWhitespaceLength;
    uint  newlineLength;
    float height;
    float baseline;
    BOOL  isTrimmed;
}

/// Passed by value, so its size is part of the ABI of every Set* below.
struct DWRITE_TEXT_RANGE
{
    uint startPosition;
    uint length;
}

struct DWRITE_MATRIX
{
    float m11, m12, m21, m22, dx, dy;
}

// ----------------------------------------------------------------- GUIDs --

immutable IID IID_IDWriteFactory =
    IID(0xb859ee5a, 0xd838, 0x4b5b, [0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48]);

// ------------------------------------------------------------ interfaces --

interface IDWriteRenderingParams : IUnknown
{
extern (Windows):
    float GetGamma();
    float GetEnhancedContrast();
    float GetClearTypeLevel();
    int   GetPixelGeometry();
    int   GetRenderingMode();
}

interface IDWriteTextFormat : IUnknown
{
extern (Windows):
    HRESULT SetTextAlignment(int textAlignment);
    HRESULT SetParagraphAlignment(int paragraphAlignment);
    HRESULT SetWordWrapping(int wordWrapping);
    HRESULT SetReadingDirection(int readingDirection);
    HRESULT SetFlowDirection(int flowDirection);
    HRESULT SetIncrementalTabStop(float incrementalTabStop);
    HRESULT SetTrimming(const(void)* trimmingOptions, void* trimmingSign);
    HRESULT SetLineSpacing(int lineSpacingMethod, float lineSpacing, float baseline);
    int     GetTextAlignment();
    int     GetParagraphAlignment();
    int     GetWordWrapping();
    int     GetReadingDirection();
    int     GetFlowDirection();
    float   GetIncrementalTabStop();
    HRESULT GetTrimming(void* trimmingOptions, void** trimmingSign);
    HRESULT GetLineSpacing(int* lineSpacingMethod, float* lineSpacing, float* baseline);
    HRESULT GetFontCollection(void** fontCollection);
    uint    GetFontFamilyNameLength();
    HRESULT GetFontFamilyName(wchar* fontFamilyName, uint nameSize);
    int     GetFontWeight();
    int     GetFontStyle();
    int     GetFontStretch();
    float   GetFontSize();
    uint    GetLocaleNameLength();
    HRESULT GetLocaleName(wchar* localeName, uint nameSize);
}

/*
 * Eight names below also exist on IDWriteTextFormat -- GetFontCollection,
 * GetFontFamilyNameLength, GetFontFamilyName, GetFontWeight, GetFontStyle,
 * GetFontStretch, GetFontSize, GetLocaleNameLength and GetLocaleName.  Every
 * one of them takes a different number of parameters here, and that is what
 * keeps this interface correct.
 *
 * In D a method that repeats an inherited name with a DIFFERENT signature is
 * an overload and gets a vtable slot of its own, which is what the header
 * describes.  Repeat one with the SAME signature and it overrides instead,
 * silently reusing the base's slot -- every method after it in this list then
 * calls the one above it, and the failure surfaces as garbage metrics or an
 * access violation somewhere else entirely.
 *
 * So: parameter lists here may lose their types to void*, but never their
 * count.  The trailing DWRITE_TEXT_RANGE* of the getters is optional in C++
 * and mandatory here for exactly that reason.
 */
interface IDWriteTextLayout : IDWriteTextFormat
{
extern (Windows):
    HRESULT SetMaxWidth(float maxWidth);
    HRESULT SetMaxHeight(float maxHeight);
    HRESULT SetFontCollection(void* fontCollection, DWRITE_TEXT_RANGE textRange);
    HRESULT SetFontFamilyName(const(wchar)* fontFamilyName, DWRITE_TEXT_RANGE textRange);
    HRESULT SetFontWeight(int fontWeight, DWRITE_TEXT_RANGE textRange);
    HRESULT SetFontStyle(int fontStyle, DWRITE_TEXT_RANGE textRange);
    HRESULT SetFontStretch(int fontStretch, DWRITE_TEXT_RANGE textRange);
    HRESULT SetFontSize(float fontSize, DWRITE_TEXT_RANGE textRange);
    HRESULT SetUnderline(BOOL hasUnderline, DWRITE_TEXT_RANGE textRange);
    HRESULT SetStrikethrough(BOOL hasStrikethrough, DWRITE_TEXT_RANGE textRange);
    HRESULT SetDrawingEffect(IUnknown drawingEffect, DWRITE_TEXT_RANGE textRange);
    HRESULT SetInlineObject(void* inlineObject, DWRITE_TEXT_RANGE textRange);
    HRESULT SetTypography(void* typography, DWRITE_TEXT_RANGE textRange);
    HRESULT SetLocaleName(const(wchar)* localeName, DWRITE_TEXT_RANGE textRange);
    float   GetMaxWidth();
    float   GetMaxHeight();
    HRESULT GetFontCollection(uint currentPosition, void** fontCollection, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetFontFamilyNameLength(uint currentPosition, uint* nameLength, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetFontFamilyName(uint currentPosition, wchar* fontFamilyName, uint nameSize, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetFontWeight(uint currentPosition, int* fontWeight, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetFontStyle(uint currentPosition, int* fontStyle, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetFontStretch(uint currentPosition, int* fontStretch, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetFontSize(uint currentPosition, float* fontSize, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetUnderline(uint currentPosition, BOOL* hasUnderline, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetStrikethrough(uint currentPosition, BOOL* hasStrikethrough, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetDrawingEffect(uint currentPosition, IUnknown* drawingEffect, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetInlineObject(uint currentPosition, void** inlineObject, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetTypography(uint currentPosition, void** typography, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetLocaleNameLength(uint currentPosition, uint* nameLength, DWRITE_TEXT_RANGE* textRange);
    HRESULT GetLocaleName(uint currentPosition, wchar* localeName, uint nameSize, DWRITE_TEXT_RANGE* textRange);
    HRESULT Draw(void* clientDrawingContext, void* renderer, float originX, float originY);
    HRESULT GetLineMetrics(DWRITE_LINE_METRICS* lineMetrics, uint maxLineCount, uint* actualLineCount);
    HRESULT GetMetrics(DWRITE_TEXT_METRICS* textMetrics);
    HRESULT GetOverhangMetrics(void* overhangs);
    HRESULT GetClusterMetrics(void* clusterMetrics, uint maxClusterCount, uint* actualClusterCount);
    HRESULT DetermineMinWidth(float* minWidth);
    HRESULT HitTestPoint(float pointX, float pointY, BOOL* isTrailingHit, BOOL* isInside, void* hitTestMetrics);
    HRESULT HitTestTextPosition(uint textPosition, BOOL isTrailingHit, float* pointX, float* pointY, void* hitTestMetrics);
    HRESULT HitTestTextRange(uint textPosition, uint textLength, float originX, float originY,
                             void* hitTestMetrics, uint maxHitTestMetricsCount, uint* actualHitTestMetricsCount);
}

interface IDWriteFactory : IUnknown
{
extern (Windows):
    HRESULT GetSystemFontCollection(void** fontCollection, BOOL checkForUpdates);
    HRESULT CreateCustomFontCollection(void* collectionLoader, const(void)* collectionKey,
                                       uint collectionKeySize, void** fontCollection);
    HRESULT RegisterFontCollectionLoader(void* fontCollectionLoader);
    HRESULT UnregisterFontCollectionLoader(void* fontCollectionLoader);
    HRESULT CreateFontFileReference(const(wchar)* filePath, const(FILETIME)* lastWriteTime,
                                    void** fontFile);
    HRESULT CreateCustomFontFileReference(const(void)* fontFileReferenceKey,
                                          uint fontFileReferenceKeySize,
                                          void* fontFileLoader, void** fontFile);
    HRESULT CreateFontFace(int fontFaceType, uint numberOfFiles, void** fontFiles,
                           uint faceIndex, int fontFaceSimulationFlags, void** fontFace);
    HRESULT CreateRenderingParams(IDWriteRenderingParams* renderingParams);
    HRESULT CreateMonitorRenderingParams(HANDLE monitor, IDWriteRenderingParams* renderingParams);
    HRESULT CreateCustomRenderingParams(float gamma, float enhancedContrast, float clearTypeLevel,
                                        int pixelGeometry, int renderingMode,
                                        IDWriteRenderingParams* renderingParams);
    HRESULT RegisterFontFileLoader(void* fontFileLoader);
    HRESULT UnregisterFontFileLoader(void* fontFileLoader);
    HRESULT CreateTextFormat(const(wchar)* fontFamilyName, void* fontCollection,
                             int fontWeight, int fontStyle, int fontStretch,
                             float fontSize, const(wchar)* localeName,
                             IDWriteTextFormat* textFormat);
    HRESULT CreateTypography(void** typography);
    HRESULT GetGdiInterop(void** gdiInterop);
    HRESULT CreateTextLayout(const(wchar)* string_, uint stringLength,
                             IDWriteTextFormat textFormat, float maxWidth, float maxHeight,
                             IDWriteTextLayout* textLayout);
    HRESULT CreateGdiCompatibleTextLayout(const(wchar)* string_, uint stringLength,
                                          IDWriteTextFormat textFormat,
                                          float layoutWidth, float layoutHeight,
                                          float pixelsPerDip, const(DWRITE_MATRIX)* transform,
                                          BOOL useGdiNatural, IDWriteTextLayout* textLayout);
    HRESULT CreateEllipsisTrimmingSign(void* textFormat, void** trimmingSign);
    HRESULT CreateTextAnalyzer(void** textAnalyzer);
    HRESULT CreateNumberSubstitution(int substitutionMethod, const(wchar)* localeName,
                                     BOOL ignoreUserOverride, void** numberSubstitution);
    HRESULT CreateGlyphRunAnalysis(const(void)* glyphRun, float pixelsPerDip,
                                   const(DWRITE_MATRIX)* transform, int renderingMode,
                                   int measuringMode, float baselineOriginX, float baselineOriginY,
                                   void** glyphRunAnalysis);
}

// ------------------------------------------------------------- functions --

extern (Windows) HRESULT DWriteCreateFactory(int factoryType, const(IID)* iid,
                                             IDWriteFactory* factory) nothrow;
