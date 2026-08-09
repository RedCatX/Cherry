module cherry.platform.win32.text;

version (Windows):

import core.sys.windows.windows;
import std.conv : to;
import std.utf : toUTF16, toUTF16z;

import cherry.platform.render;
import cherry.platform.win32.dwrite;

pragma(lib, "user32");
pragma(lib, "gdi32");

// Not in druntime's headers.  The locale decides where lines may break and
// which font a character not in the family falls back to, so asking for the
// user's own is part of looking like the system rather than a nicety.
private extern (Windows) int GetUserDefaultLocaleName(wchar* localeName, int cchLocaleName) nothrow @nogc;

private enum LOCALE_NAME_MAX_LENGTH_ = 85;

/*
 * A layout has to be given a box, and infinity is not one: DirectWrite takes
 * the extents as floats and an infinite one produces a layout of no width at
 * all.  This is what an unbounded offer is mapped to -- far larger than any
 * screen, small enough that nothing overflows when it is added to a coordinate.
 *
 * It is only ever the box.  A layout that does not wrap reports the width it
 * really needs whatever box it was given, so this number never reaches an
 * answer.
 */
private enum float unboundedExtent = 1.0e6f;

/**
 * The font the system writes its own interface in: what SPI_GETNONCLIENTMETRICS
 * reports as the message font, which on Windows 11 is Segoe UI at 12.
 *
 * The same source WPF reads for SystemFonts.MessageFontFamily, and the reason a
 * control with no font of its own is mistakable for a native one.
 *
 * user32 and gdi32 only -- no COM, nothing lazily created, nothing that can
 * fail slowly.  That is deliberate: this is called from a module constructor,
 * where creating a DirectWrite factory would be both wasteful and a hazard.
 *
 * Wrapping and rendering are left at their defaults, because this describes a
 * font and not a whole request.
 */
TextFormat systemTextFormat()
{
    TextFormat format;

    NONCLIENTMETRICSW metrics;
    metrics.cbSize = NONCLIENTMETRICSW.sizeof;

    // druntime's NONCLIENTMETRICSW is the pre-Vista layout, one int shorter
    // than the current one.  Windows dispatches on cbSize and fills the older
    // shape, and lfMessageFont is in both, so the older shape is enough.
    if (!SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, metrics.cbSize, &metrics, 0))
        return format;

    auto font = metrics.lfMessageFont;

    size_t length = 0;
    while (length < font.lfFaceName.length && font.lfFaceName[length] != 0)
        ++length;

    if (length > 0)
        format.family = to!string(font.lfFaceName[0 .. length]);

    // lfHeight is negative for the em size and positive for the cell height;
    // the message font gives the former, and taking the magnitude keeps a
    // machine configured the other way readable rather than tiny.
    immutable pixels = font.lfHeight < 0 ? -font.lfHeight : font.lfHeight;

    if (pixels > 0)
    {
        // Logical units to device-independent ones.  Both are 96 while the
        // process is DPI-unaware, so today this divides by one -- it is here so
        // that the arithmetic is already right on the day the process is not.
        // See the note in win32/window.d's invalidate, which is the other place
        // the two spaces meet.
        auto screen = GetDC(null);
        immutable dpi = screen is null ? 96 : GetDeviceCaps(screen, LOGPIXELSY);
        if (screen !is null)
            ReleaseDC(null, screen);

        format.size = pixels * 96.0f / (dpi > 0 ? dpi : 96);
    }

    if (font.lfWeight > 0)
        format.weight = cast(FontWeight) font.lfWeight;

    if (font.lfItalic)
        format.style = FontStyle.italic;

    return format;
}

/**
 * DirectWrite implementation of TextService.
 *
 * The factory is DirectWrite's shared one, which the system hands out per
 * process and which owns the font cache: two services on two threads measure
 * against the same fonts and pay for reading them once.
 */
final class DWriteTextService : TextService
{
    this()
    {
        _factory = dwriteFactory();
    }

   /**
    * Lays the text out through whichever of DirectWrite's two paths the
    * format's rendering mode names.
    *
    * A text format object is made and released around each layout.  It is the
    * cheap half -- DirectWrite caches the font behind it, and the layout is
    * what actually costs -- and callers hold their layouts across frames, so
    * this runs when something really changed rather than once a frame.
    */
    TextLayout createLayout(string text, TextFormat format, Size available)
    {
        auto family = format.family.length > 0 ? format.family : systemTextFormat().family;

        IDWriteTextFormat textFormat;
        auto hr = _factory.CreateTextFormat(family.toUTF16z(), null,
                                            cast(int) format.weight,
                                            toDWriteStyle(format.style),
                                            DWRITE_FONT_STRETCH_NORMAL,
                                            format.size, localeName().ptr,
                                            &textFormat);
        if (hr != S_OK)
            throw new Exception(failed("Failed to create the DirectWrite text format.", hr));

        scope (exit) textFormat.Release();

        immutable wraps = format.wrapping == TextWrapping.wrap
                       && available.width < float.infinity;

        textFormat.SetWordWrapping(wraps ? DWRITE_WORD_WRAPPING_WRAP
                                         : DWRITE_WORD_WRAPPING_NO_WRAP);

        immutable width  = wraps ? available.width : unboundedExtent;
        immutable height = available.height < float.infinity ? available.height : unboundedExtent;

        auto utf16 = text.toUTF16();

        // An empty D array has a null pointer, and DirectWrite refuses a null
        // string with E_INVALIDARG even when the length is zero.  Measuring
        // nothing is an ordinary thing to ask -- an empty label still has a
        // line's height -- so it gets a pointer to nothing instead.
        auto characters = utf16.length > 0 ? utf16.ptr : ""w.ptr;

        IDWriteTextLayout layout;

        if (format.rendering == TextRendering.display)
        {
            // pixelsPerDip is the only place DPI enters the text path.  One
            // while the process is DPI-unaware; the day it is not, this is the
            // scale, and it belongs here rather than anywhere further out --
            // grid-fitting has to know what a pixel is.
            //
            // useGdiNatural false is GDI classic: whole-pixel advances, the
            // widths a Win32 control lays out with.
            hr = _factory.CreateGdiCompatibleTextLayout(characters, cast(uint) utf16.length,
                                                        textFormat, width, height,
                                                        1.0f, null, FALSE, &layout);
        }
        else
        {
            hr = _factory.CreateTextLayout(characters, cast(uint) utf16.length,
                                           textFormat, width, height, &layout);
        }

        if (hr != S_OK)
            throw new Exception(failed("Failed to lay the text out with DirectWrite.", hr));

        DWRITE_TEXT_METRICS textMetrics;
        hr = layout.GetMetrics(&textMetrics);
        if (hr != S_OK)
        {
            layout.Release();
            throw new Exception(failed("Failed to measure the DirectWrite text layout.", hr));
        }

        // width and not widthIncludingTrailingWhitespace: spaces typed at the
        // end of a line do not make an element wider, which is what WPF
        // measures too.
        return new DWriteTextLayout(layout, text, format,
                                    Size(textMetrics.width, textMetrics.height));
    }

private:
    IDWriteFactory _factory;
}

/**
 * A laid-out run of text over an IDWriteTextLayout.
 *
 * The same object answers the size and is handed to Direct2D to be drawn, so
 * what was measured is what appears.
 */
final class DWriteTextLayout : TextLayout
{
    @property Size size() { return _size; }
    @property string text() { return _text; }
    @property TextFormat format() { return _format; }

    void dispose()
    {
        if (_native is null)
            return;

        _native.Release();
        _native = null;
    }

   /*
    * A net under dispose, not a replacement for it.  The deterministic path is
    * the control giving its old layout back when the text or the font changes;
    * this is what keeps a layout nobody kept from leaking until the process
    * ends.  Release is an interlocked decrement and is safe to make from a
    * finalizer.
    */
    ~this()
    {
        dispose();
    }

package:
    this(IDWriteTextLayout native, string text, TextFormat format, Size size)
    {
        _native = native;
        _text = text;
        _format = format;
        _size = size;
    }

    /// What Direct2D is given to draw.  Null once disposed.
    @property IDWriteTextLayout native() { return _native; }

private:
    IDWriteTextLayout _native;
    string            _text;
    TextFormat        _format;
    Size              _size;
}

/**
 * DirectWrite's shared factory for this process.
 *
 * Shared rather than isolated so that the font cache is shared too, and cached
 * here as well because DWriteCreateFactory adds a reference on every call.
 */
package IDWriteFactory dwriteFactory()
{
    synchronized
    {
        if (s_factory is null)
        {
            IDWriteFactory factory;
            auto hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
                                          &IID_IDWriteFactory, &factory);
            if (hr != S_OK)
                throw new Exception("Failed to create the DirectWrite factory.");

            s_factory = cast(shared) factory;
        }

        return cast(IDWriteFactory) s_factory;
    }
}

private:

shared IDWriteFactory s_factory;

/*
 * A failure message with the code in it.
 *
 * Bare messages are enough elsewhere in the backend, and not here.  These
 * bindings are transcribed by hand, so the first suspicion when a call fails is
 * always the transcription -- and the code is what separates that from an
 * argument DirectWrite would not take.  E_INVALIDARG on a null string pointer
 * is exactly the case: it looks like a broken vtable and is not one.
 */
string failed(string what, HRESULT hr)
{
    import std.format : format;

    return format("%s  (HRESULT 0x%08X)", what, hr);
}

int toDWriteStyle(FontStyle style) pure nothrow @nogc
{
    final switch (style)
    {
        case FontStyle.normal:  return DWRITE_FONT_STYLE_NORMAL;
        case FontStyle.oblique: return DWRITE_FONT_STYLE_OBLIQUE;
        case FontStyle.italic:  return DWRITE_FONT_STYLE_ITALIC;
    }
}

/*
 * The user's locale, zero-terminated, or a neutral one if the system will not
 * say.  Read once: it cannot change without the user signing out.
 */
const(wchar)[] localeName()
{
    if (s_locale.length == 0)
    {
        wchar[LOCALE_NAME_MAX_LENGTH_] buffer;
        immutable length = GetUserDefaultLocaleName(buffer.ptr, buffer.length);

        // The count includes the terminator, which is what CreateTextFormat
        // wants at the end of what it is given.
        s_locale = length > 0 ? buffer[0 .. length].idup : "en-us\0"w;
    }

    return s_locale;
}

immutable(wchar)[] s_locale;

// ----------------------------------------------------------------- tests --

unittest
{
    // Vtable probes.  Nothing verifies the order of COM slots -- not the
    // compiler, not the linker, not the loader -- so these three calls are the
    // entire guard on the one file in the framework where a transcription slip
    // costs an access violation somewhere else entirely.
    //
    // They are spread on purpose: GetFontSize is the 23rd of IDWriteTextFormat's
    // 25, GetMaxWidth the 15th of the 39 that follow it, and GetMetrics the
    // 33rd of those.  A missing or extra slot anywhere before one of them makes
    // it call its neighbour, and a neighbour returning a plausible number is
    // exactly what these known answers rule out.
    auto service = new DWriteTextService;

    auto format = TextFormat.init;
    format.size = 20;
    format.wrapping = TextWrapping.wrap;

    auto layout = cast(DWriteTextLayout) service.createLayout("Probe", format, Size(500, 100));
    assert(layout !is null);
    scope (exit) layout.dispose();

    // Through a base-typed reference, because the derived interface's own
    // GetFontSize hides the inherited one by name -- D's rule, and a matter of
    // lookup rather than of layout.  The slot is still there, which is what
    // this reads.
    auto asFormat = cast(IDWriteTextFormat) layout.native;
    assert(asFormat.GetFontSize() == 20,
           "the base interface's slots are intact, and the derived one did not "
           ~ "reuse this slot for its own three-argument GetFontSize");
    assert(layout.native.GetMaxWidth() == 500, "the box the layout was given");

    DWRITE_TEXT_METRICS metrics;
    assert(layout.native.GetMetrics(&metrics) == S_OK);
    assert(metrics.layoutWidth == 500, "and GetMetrics agrees about it");
}

unittest
{
    // What the real backend can honestly promise about a real font.  Anything
    // tighter would be asserting on which build of Windows is running.
    auto service = new DWriteTextService;

    auto laid = service.createLayout("Cherry", TextFormat.init, Size(500, 100));
    scope (exit) laid.dispose();

    assert(laid.size.width > 0 && laid.size.width < 500);
    assert(laid.size.height > 0);
    assert(laid.text == "Cherry");

    auto empty = service.createLayout("", TextFormat.init, Size(500, 100));
    scope (exit) empty.dispose();

    assert(empty.size.width == 0);
    assert(empty.size.height == laid.size.height,
           "nothing typed on it, but a line is still a line high");

    // A bigger font is bigger, which is the cheapest statement that the size
    // reaches DirectWrite at all.
    auto big = TextFormat.init;
    big.size = 24;

    auto larger = service.createLayout("Cherry", big, Size(500, 100));
    scope (exit) larger.dispose();

    assert(larger.size.width > laid.size.width);
    assert(larger.size.height > laid.size.height);
}

unittest
{
    // The two rendering modes are two different calls, and this is what says
    // so from the outside.
    //
    // A GDI-compatible layout advances by whole pixels and stacks whole-pixel
    // lines, so its box comes out on integers; that is the definitive half.
    // The sizes then differing is the other half -- for a string this long the
    // unrounded widths summing to the rounded ones would be a coincidence, and
    // if this ever fails on some font it means the display path is answering
    // for both.
    import std.math : floor;

    auto service = new DWriteTextService;
    enum sample = "The quick brown fox jumps over the lazy dog.";

    auto display = TextFormat.init;
    auto ideal = TextFormat.init;
    ideal.rendering = TextRendering.ideal;

    auto crisp = service.createLayout(sample, display, Size(1000, 100));
    scope (exit) crisp.dispose();

    auto smooth = service.createLayout(sample, ideal, Size(1000, 100));
    scope (exit) smooth.dispose();

    assert(crisp.size.width == floor(crisp.size.width), "whole-pixel advances");
    assert(crisp.size.height == floor(crisp.size.height), "and whole-pixel lines");
    assert(crisp.size != smooth.size, "two paths, two answers");
}

unittest
{
    // Wrapping is off until asked for, and then the room decides the breaks.
    auto service = new DWriteTextService;
    enum sample = "The quick brown fox jumps over the lazy dog.";

    auto straight = service.createLayout(sample, TextFormat.init, Size(80, 500));
    scope (exit) straight.dispose();

    auto wrapping = TextFormat.init;
    wrapping.wrapping = TextWrapping.wrap;

    auto broken = service.createLayout(sample, wrapping, Size(80, 500));
    scope (exit) broken.dispose();

    assert(straight.size.width > 80, "no wrapping, so the room is not a limit");
    assert(broken.size.width <= 80);
    assert(broken.size.height > straight.size.height, "what was gained in width is paid in lines");

    // An unbounded offer has nothing to break at, so it does not break.
    auto unbounded = service.createLayout(sample, wrapping, Size(float.infinity, 500));
    scope (exit) unbounded.dispose();

    assert(unbounded.size.width == straight.size.width);
}

unittest
{
    // The system's own font, asserted against what is true on any Windows
    // rather than against this machine's shell font.
    immutable system = systemTextFormat();

    assert(system.family.length > 0, "the system always has a font");
    assert(system.size > 0 && system.size < 100);
    assert(system.wrapping == TextWrapping.noWrap, "it describes a font, not a request");

    // Asking for it by name and asking for it by leaving the name out are the
    // same request.
    auto service = new DWriteTextService;

    auto named = TextFormat.init;
    named.family = system.family;
    named.size = system.size;

    auto blank = TextFormat.init;
    blank.size = system.size;

    auto byName = service.createLayout("Cherry", named, Size(500, 100));
    scope (exit) byName.dispose();

    auto byDefault = service.createLayout("Cherry", blank, Size(500, 100));
    scope (exit) byDefault.dispose();

    assert(byName.size == byDefault.size);
}

unittest
{
    // Disposing twice is not an error, and neither is letting the finalizer
    // find one that was disposed.
    auto service = new DWriteTextService;
    auto layout = cast(DWriteTextLayout) service.createLayout("Cherry", TextFormat.init, Size(500, 100));

    assert(layout.native !is null);
    layout.dispose();
    assert(layout.native is null);
    layout.dispose();
}
