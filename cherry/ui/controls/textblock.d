module cherry.ui.controls.textblock;

/*
 * A module constructor here is safe for the reason stackpanel.d's banner
 * spells out: the imports of this package run one way.  This module imports
 * the element tree and the platform; nothing in either imports a control.
 *
 * The platform is the new part.  cherry.platform and everything under it carry
 * no module constructor at all, so nothing here can join a cycle by reaching
 * into it -- and systemTextFormat is deliberately the one platform call that
 * needs no COM and nothing lazily built, which is what makes it callable from
 * the constructor below.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform : systemTextFormat, textService;
import cherry.platform.render : Color, DrawingContext, FontStyle, FontWeight, Point,
                                Size, TextFormat, TextLayout, TextRendering, TextWrapping;
import cherry.ui.element;

/**
 * Draws a run of text.
 *
 * With nothing set it uses the font the system writes its own interface in, at
 * the size the system uses, rasterised the way a Win32 control is -- so a label
 * that nobody has styled is meant to be indistinguishable from a native one.
 * Every part of that is a property, and each can be overridden on its own.
 *
 * The text is laid out once and kept.  Measuring is what builds the layout, and
 * drawing uses the very object that was measured, so what appears is the size
 * the element asked its parent for.  A change to anything the layout depends on
 * invalidates the measure, and the next pass builds another.
 *
 * Two things it does not do yet, named so that nobody looks for them:
 *
 * The font properties **do not inherit**.  Setting FontSize on a panel leaves
 * its children alone, because a change to an inherited value does not reach the
 * elements that inherit it -- nothing walks down the tree on assignment.  They
 * belong on Control once there is one, and they can become inherited on the day
 * that walk exists; until then a property that looked as if it cascaded and
 * quietly did not would be worse than one that never claimed to.
 *
 * renderBounds is the element's own bounds, and text can exceed them.  Accents,
 * descenders and the side bearings of an italic all reach past the box the
 * layout reports, so the region asked for on a repaint is a little too small.
 * DirectWrite will say by how much -- GetOverhangMetrics -- and until something
 * clips, the whole cost is a dirty rectangle that understates itself on a
 * backend which presents the whole window anyway.
 */
class TextBlock : Element
{
    shared static this()
    {
        // The system's own font, read once here, exactly as WPF takes its
        // defaults from SystemFonts.  It is what makes an unstyled label look
        // native without anybody writing a font name.
        immutable system = systemTextFormat();

        // Everything about the text changes how much room it needs, so all of
        // it is a measure and none of it is merely an arrange.  The parent
        // hears about it on its own: invalidateMeasure walks up.
        PropertyMetadata textMeta;
        textMeta.defaultValue = Value("");
        textMeta.affectsMeasure = true;

        textProperty = Property.register("Text", getRtti!string(), getRtti!TextBlock(), textMeta);

        PropertyMetadata familyMeta;
        familyMeta.defaultValue = Value(system.family);
        familyMeta.affectsMeasure = true;

        fontFamilyProperty = Property.register("FontFamily",
            getRtti!string(), getRtti!TextBlock(), familyMeta);

        PropertyMetadata sizeMeta;
        sizeMeta.defaultValue = Value(system.size);
        sizeMeta.affectsMeasure = true;

        fontSizeProperty = Property.register("FontSize",
            getRtti!float(), getRtti!TextBlock(), sizeMeta, &isUsableFontSize);

        PropertyMetadata weightMeta;
        weightMeta.defaultValue = Value(system.weight);
        weightMeta.affectsMeasure = true;

        fontWeightProperty = Property.register("FontWeight",
            getRtti!FontWeight(), getRtti!TextBlock(), weightMeta);

        PropertyMetadata styleMeta;
        styleMeta.defaultValue = Value(system.style);
        styleMeta.affectsMeasure = true;

        fontStyleProperty = Property.register("FontStyle",
            getRtti!FontStyle(), getRtti!TextBlock(), styleMeta);

        PropertyMetadata wrappingMeta;
        wrappingMeta.defaultValue = Value(TextWrapping.noWrap);
        wrappingMeta.affectsMeasure = true;

        textWrappingProperty = Property.register("TextWrapping",
            getRtti!TextWrapping(), getRtti!TextBlock(), wrappingMeta);

        PropertyMetadata renderingMeta;
        renderingMeta.defaultValue = Value(TextRendering.display);
        renderingMeta.affectsMeasure = true;

        textRenderingProperty = Property.register("TextRendering",
            getRtti!TextRendering(), getRtti!TextBlock(), renderingMeta);

        // The colour is the one thing here that changes nothing about how much
        // room the text needs -- the glyphs are in the same places, in a
        // different ink.  affectsRender is exactly that statement, and this is
        // the first property in the framework entitled to make it.
        PropertyMetadata foregroundMeta;
        foregroundMeta.defaultValue = Value(Color.black);
        foregroundMeta.affectsRender = true;

        foregroundProperty = Property.register("Foreground",
            getRtti!Color(), getRtti!TextBlock(), foregroundMeta);
    }

    static immutable(Property) textProperty;
    static immutable(Property) fontFamilyProperty;
    static immutable(Property) fontSizeProperty;
    static immutable(Property) fontWeightProperty;
    static immutable(Property) fontStyleProperty;
    static immutable(Property) textWrappingProperty;
    static immutable(Property) textRenderingProperty;
    static immutable(Property) foregroundProperty;

    /// What to write.  Empty by default, which is still a line high.
    @property string text() const
    {
        return getValue(textProperty).get!string;
    }

    /// ditto
    @property void text(string value)
    {
        setValue(textProperty, Value(value));
    }

   /**
    * The family to write it in.  The system's message font by default.
    *
    * An empty name means the system's too, so clearing this and never setting
    * it come to the same thing.
    */
    @property string fontFamily() const
    {
        return getValue(fontFamilyProperty).get!string;
    }

    /// ditto
    @property void fontFamily(string value)
    {
        setValue(fontFamilyProperty, Value(value));
    }

   /**
    * The em size, in device-independent units rather than points -- the same
    * units as every other length in the framework.
    *
    * The system's default is 12, which is the nine points Windows has written
    * its interface in since Vista.
    */
    @property float fontSize() const
    {
        return getValue(fontSizeProperty).get!float;
    }

    /// ditto
    @property void fontSize(float value)
    {
        setValue(fontSizeProperty, Value(value));
    }

    /// How heavy the strokes are, and whether the face is slanted.
    @property FontWeight fontWeight() const
    {
        return getValue(fontWeightProperty).get!FontWeight;
    }

    /// ditto
    @property void fontWeight(FontWeight value)
    {
        setValue(fontWeightProperty, Value(value));
    }

    /// ditto
    @property FontStyle fontStyle() const
    {
        return getValue(fontStyleProperty).get!FontStyle;
    }

    /// ditto
    @property void fontStyle(FontStyle value)
    {
        setValue(fontStyleProperty, Value(value));
    }

   /**
    * Whether the text may be broken across lines.
    *
    * Off by default, as in WPF: a label that silently rearranges itself when
    * its container narrows is a surprise, and a label that overflows is a
    * visible one.  Turned on, the width offered by the parent decides where the
    * breaks fall, and the element grows downwards instead of sideways.
    */
    @property TextWrapping textWrapping() const
    {
        return getValue(textWrappingProperty).get!TextWrapping;
    }

    /// ditto
    @property void textWrapping(TextWrapping value)
    {
        setValue(textWrappingProperty, Value(value));
    }

   /**
    * Which of the two pictures of the system font the text is drawn as -- see
    * TextRendering, which explains why there are two.
    *
    * It affects the measured width and not only the appearance, which is why
    * it invalidates the measure and why it lives on the element rather than in
    * the backend.  When there are themes this is what a theme will set.
    */
    @property TextRendering textRendering() const
    {
        return getValue(textRenderingProperty).get!TextRendering;
    }

    /// ditto
    @property void textRendering(TextRendering value)
    {
        setValue(textRenderingProperty, Value(value));
    }

    /// The ink.  Black until there are system colours to ask.
    @property Color foreground() const
    {
        return getValue(foregroundProperty).get!Color;
    }

    /// ditto
    @property void foreground(Color value)
    {
        setValue(foregroundProperty, Value(value));
    }

   /**
    * Everything about the text gathered into one value, as the text service
    * wants it.
    *
    * Assembled here and not stored, because a struct with a string in it cannot
    * be a property value: a Value compares a struct byte for byte, so the
    * family would be compared by its pointer and every assignment would look
    * like a change.  TextFormat says the same thing at more length.
    */
    @property TextFormat format() const
    {
        TextFormat result;
        result.family    = fontFamily;
        result.size      = fontSize;
        result.weight    = fontWeight;
        result.style     = fontStyle;
        result.wrapping  = textWrapping;
        result.rendering = textRendering;
        return result;
    }

protected:
   /**
    * Lays the text out, if it is not already laid out the same way, and asks
    * for exactly the room it takes.
    *
    * Children are not measured and there is no call to super: a TextBlock has
    * content of its own rather than a place to put somebody else's, and the
    * default single-cell behaviour would quietly make it one.
    */
    override Size measureOverride(Size availableSize)
    {
        return ensureLayout(availableSize).size;
    }

   /**
    * Draws the layout that was measured, at the element's own origin.
    *
    * Nothing is measured here.  If there is no layout the element was never
    * measured, and drawing something worked out on the spot would put text on
    * the screen at a size nobody has been told about.
    */
    override void onRender(DrawingContext context)
    {
        if (_layout is null)
            return;

        context.drawText(_layout, Point(0, 0), foreground);
    }

private:
   /*
    * The layout for the current text, format and room, building one only when
    * what it depends on has really changed.
    *
    * Kept because building one is the expensive half of measuring and a pass
    * runs whenever anything anywhere in the tree moves.  The old one is given
    * back the moment it is replaced rather than left to the collector: it owns
    * a native object, and a control being resized produces one per pass.
    *
    * The room enters the key only when the text wraps.  Without wrapping the
    * answer does not depend on what was offered -- the layout reports the width
    * it needs and overflows if that is more -- so narrowing the parent would
    * otherwise rebuild every layout in the window for nothing.
    */
    TextLayout ensureLayout(Size available)
    {
        immutable wanted = format;
        immutable constraint = wanted.wrapping == TextWrapping.wrap
                             ? available.width : float.infinity;

        if (_layout !is null
            && _layoutText == text
            && _layoutFormat == wanted
            && _layoutConstraint == constraint)
            return _layout;

        auto built = textService.createLayout(text, wanted, available);

        if (_layout !is null)
            _layout.dispose();

        _layout = built;
        _layoutText = text;
        _layoutFormat = wanted;
        _layoutConstraint = constraint;

        return _layout;
    }

    TextLayout _layout;
    string     _layoutText;
    TextFormat _layoutFormat;
    float      _layoutConstraint = float.nan;
}

/*
 * A font size is a length, and neither zero, a negative, an infinity nor a NaN
 * is one a face can be rendered at.
 *
 * Refused here so that the assignment is named.  Left to reach DirectWrite it
 * would come back as E_INVALIDARG from inside a measure, pointing at a call the
 * caller never wrote; and a NaN would sail past that only to poison the sums of
 * every ancestor.
 *
 * Written as two comparisons rather than through std.math.isFinite because NaN
 * fails both of them, which is the point.
 */
private bool isUsableFontSize(const(Value) value)
{
    immutable size = value.get!float;
    return size > 0 && size < float.infinity;
}

version (unittest)
{
    import cherry.core.threading : Dispatcher;
    import cherry.core.threading.testing : withDispatcher;
    import cherry.platform : textService;
    import cherry.platform.eventloop : ManualEventLoop;
    import cherry.platform.render : FakeTextService, RecordingContext, Rect;
    import cherry.ui.controls.stackpanel : StackPanel;

    import std.exception : assertThrown;

   /*
    * Runs body against metrics chosen in advance rather than against whatever
    * font this machine happens to have, putting the platform's own service
    * back afterwards whatever happens -- the slot is thread-wide, and a fake
    * left in it would measure for every test that ran next.
    */
    private void withFakeText(scope void delegate(FakeTextService) body)
    {
        auto original = textService;
        scope (exit) textService = original;

        auto fake = new FakeTextService;
        textService = fake;
        body(fake);
    }

   /*
    * The top of a tree with somewhere to put pixels, recording what it was
    * asked to repaint.  layout.d keeps one of these for the same reason and
    * explains at length why it is an Element and not a Window.
    */
    private class Surface : Element
    {
        Rect[] repaints;

        override void repaintAsRoot(Rect region)
        {
            repaints ~= region;
        }
    }
}

unittest
{
    // A label nobody has styled is the system's own font, and the test says so
    // by asking the system rather than by naming Segoe UI: a machine whose
    // shell font is something else is still a machine this works on.
    immutable system = systemTextFormat();

    auto label = new TextBlock;

    assert(label.fontFamily == system.family);
    assert(label.fontSize == system.size);
    assert(label.fontWeight == system.weight);
    assert(label.fontStyle == system.style);

    assert(label.text == "", "nothing to say until told");
    assert(label.textWrapping == TextWrapping.noWrap);
    assert(label.textRendering == TextRendering.display,
           "drawn the way a Win32 control is, until a theme says otherwise");
    assert(label.foreground == Color.black);

    // And the assembled request is the parts, unchanged.
    immutable f = label.format;
    assert(f.family == system.family && f.size == system.size);
    assert(f.wrapping == TextWrapping.noWrap && f.rendering == TextRendering.display);
}

unittest
{
    // A size is a length a face can be drawn at, and the refusals leave what
    // was there alone.
    auto label = new TextBlock;
    immutable was = label.fontSize;

    label.fontSize = 20;
    assert(label.fontSize == 20);

    assertThrown(label.setValue(TextBlock.fontSizeProperty, Value(0.0f)));
    assertThrown(label.setValue(TextBlock.fontSizeProperty, Value(-8.0f)));
    assertThrown(label.setValue(TextBlock.fontSizeProperty, Value(float.infinity)));
    assertThrown(label.setValue(TextBlock.fontSizeProperty, Value(float.nan)));
    assert(label.fontSize == 20);

    label.clearValue(TextBlock.fontSizeProperty);
    assert(label.fontSize == was);
}

unittest
{
    // What it asks its parent for is what the text takes, and nothing else:
    // no children are measured and the room offered is not echoed back.
    withFakeText((FakeTextService fake) {
        auto label = new TextBlock;
        label.text = "hello";

        label.measure(Size(500, 400));

        assert(label.desiredSize == Size(5 * 7, 16));
        assert(fake.created == 1);

        // An empty label is not a label of no height.
        auto blank = new TextBlock;
        blank.measure(Size(500, 400));
        assert(blank.desiredSize == Size(0, 16));
    });
}

unittest
{
    // Changing the text changes what it costs, and the parent hears about it
    // without being told: invalidateMeasure walks up.
    withFakeText((FakeTextService fake) {
        auto parent = new Element;
        auto label = new TextBlock;
        parent.addChild(label);
        label.text = "hi";

        parent.measure(Size(500, 400));
        parent.arrange(Rect(0, 0, 500, 400));
        assert(parent.desiredSize.width == 2 * 7);

        label.text = "hello";
        assert(!label.isMeasureValid);
        assert(!parent.isMeasureValid, "a longer label costs its parent more");

        parent.measure(Size(500, 400));
        assert(parent.desiredSize.width == 5 * 7);
    });
}

unittest
{
    // Wrapping trades width for lines, and the room decides where the breaks
    // fall -- but only once wrapping has been asked for.
    withFakeText((FakeTextService fake) {
        auto label = new TextBlock;
        label.text = "abcdefghij";

        label.measure(Size(21, 400));
        assert(label.unclippedDesiredSize == Size(70, 16),
               "no wrapping, so the room is not a limit and the overflow is on the record");
        assert(label.desiredSize == Size(21, 16),
               "though the parent only ever hears back what it offered");

        label.textWrapping = TextWrapping.wrap;
        label.measure(Size(21, 400));
        assert(label.desiredSize == Size(21, 4 * 16), "three to a line, so four lines");
        assert(label.unclippedDesiredSize == label.desiredSize,
               "and now it really does fit, so there is nothing to hold back");
    });
}

unittest
{
    // The layout is built once and kept.  Without a cache a pass anywhere in
    // the window would rebuild every layout in it.
    withFakeText((FakeTextService fake) {
        auto label = new TextBlock;
        label.text = "hello";

        label.measure(Size(500, 400));
        assert(fake.created == 1);

        label.invalidateMeasure();
        label.measure(Size(500, 400));
        assert(fake.created == 1, "nothing it depends on changed");

        // The room is not one of those things while the text does not wrap:
        // the answer is the same whatever was offered, so a parent narrowing
        // must not cost a rebuild.
        label.invalidateMeasure();
        label.measure(Size(80, 400));
        assert(fake.created == 1);

        // The font is, and the layout that goes is given back rather than left
        // for the collector -- it owns a native object.
        label.fontSize = 24;
        label.measure(Size(500, 400));
        assert(fake.created == 2 && fake.disposed == 1);
    });
}

unittest
{
    // Once it wraps, the room is part of the question, so a different width is
    // a different layout.
    withFakeText((FakeTextService fake) {
        auto label = new TextBlock;
        label.text = "abcdefghij";
        label.textWrapping = TextWrapping.wrap;

        label.measure(Size(70, 400));
        assert(fake.created == 1);

        label.invalidateMeasure();
        label.measure(Size(21, 400));
        assert(fake.created == 2);
        assert(fake.disposed == 1);
    });
}

unittest
{
    // Where a label lands, read off the drawing context rather than worked out
    // by the test: the panel offsets it, and renderSubtree turns the placement
    // into the coordinate space the text is drawn in.
    withFakeText((FakeTextService fake) {
        auto panel = new StackPanel;
        panel.spacing = 4;

        auto first = new TextBlock;
        first.text = "one";
        auto second = new TextBlock;
        second.text = "two";

        panel.addChild(first);
        panel.addChild(second);

        panel.measure(Size(500, 400));
        panel.arrange(Rect(0, 0, 500, 400));

        auto context = new RecordingContext;
        panel.renderSubtree(context);

        assert(context.entries.length == 2);
        assert(context.depth == 0, "and the walk left the stack as it found it");

        assert(context.entries[0].content == "one");
        assert(context.entries[0].rect == Rect(0, 0, 3 * 7, 16));

        // Down by the first label's height and the panel's gap, and across by
        // nothing -- a stack fills the width and the text starts at the left.
        assert(context.entries[1].content == "two");
        assert(context.entries[1].rect == Rect(0, 16 + 4, 3 * 7, 16));
    });
}

unittest
{
    // The colour is the one thing that changes nothing about the size, and
    // affectsRender is what says so.  This is the flag's first user.
    withFakeText((FakeTextService fake) {
        withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
            auto surface = new Surface;
            auto label = new TextBlock;
            label.text = "hello";

            // Pinned rather than stretched, so that the element is the size of
            // its text and the region asked for is worth reading.  Left to
            // stretch it would fill the surface, and the repaint would be the
            // whole of it -- true, and no evidence of anything.
            label.horizontalAlignment = HorizontalAlignment.left;
            label.verticalAlignment = VerticalAlignment.top;

            surface.addChild(label);

            surface.measure(Size(500, 400));
            surface.arrange(Rect(0, 0, 500, 400));
            surface.updateLayout();

            surface.repaints = null;
            immutable builtSoFar = fake.created;

            label.foreground = Color.rgb(1, 0, 0);

            assert(label.isMeasureValid && label.isArrangeValid,
                   "different ink, same glyphs in the same places");
            assert(!label.isVisualValid);

            surface.updateLayout();

            assert(surface.repaints.length == 1, "one region asked for, and one only");
            assert(surface.repaints[0] == Rect(0, 0, 5 * 7, 16),
                   "the label's own bounds, in the surface's space");
            assert(fake.created == builtSoFar, "and nothing was laid out again");
        });
    });
}
