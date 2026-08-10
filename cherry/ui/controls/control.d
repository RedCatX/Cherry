module cherry.ui.controls.control;

/*
 * A module constructor here is safe for the reason stackpanel.d's banner spells
 * out: the imports of this package run one way.  This one imports the element
 * tree and the media package; nothing in either imports a control.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : Color, DashStyle, DrawingContext, LineCap, Rect,
                                Size, Stroke, Thickness;
import cherry.ui.element;
import cherry.ui.event : RoutedEventArgs;
import cherry.ui.input : MouseButton, MouseEventArgs;
import cherry.ui.media.brush : Brush, SolidColorBrush;
import cherry.ui.media.pen : Pen;

/**
 * The base of the things a user works with: something with a surface of its
 * own -- a fill, a border, room kept clear inside it -- around whatever it
 * contains.
 *
 * **It draws itself today, and that is the part that will go.** In WPF a
 * Control has no appearance at all: it has a Template, and the theme puts a
 * Border and a ContentPresenter inside it.  Until templates exist somebody has
 * to paint, and it is cheaper and clearer for the control to do it than to
 * invent half a template.  When templates arrive, onRender here goes away and
 * these same properties get bound to a Border inside the default template --
 * the properties are the part that stays.
 *
 * That is also why the drawing lives in one overridable method and nothing
 * else: what has to move later is one method, not a habit spread over five.
 *
 * **No font properties.** They sit on TextBlock, inherited values do not reach
 * descendants yet, and a second set here would have to be forwarded into the
 * label by hand -- a mechanism that exists only to be deleted.  They move when
 * inheritance does.
 */
class Control : Element
{
    shared static this()
    {
        // Unset rather than a transparent brush, and that is forced rather than
        // chosen: a brush is a CherryObject, a CherryObject binds to its
        // thread's dispatcher when it is built, and a module constructor is far
        // too early to raise one.  Unset means "do not paint this", which is
        // also the more useful default -- an unpainted control lets what is
        // behind it show, and costs nothing to draw.
        PropertyMetadata brushMeta;
        brushMeta.defaultValue = Value.init;
        brushMeta.affectsRender = true;

        backgroundProperty = Property.register("Background",
            getRtti!Brush(), getRtti!Control(), brushMeta);
        borderBrushProperty = Property.register("BorderBrush",
            getRtti!Brush(), getRtti!Control(), brushMeta);

        // Both of these take room away from the content, so both are a measure
        // and not merely a render: a border drawn over its own content would be
        // a border nobody could put anything next to.
        PropertyMetadata insetMeta;
        insetMeta.defaultValue = Value(Thickness.init);
        insetMeta.affectsMeasure = true;

        borderThicknessProperty = Property.register("BorderThickness",
            getRtti!Thickness(), getRtti!Control(), insetMeta);
        paddingProperty = Property.register("Padding",
            getRtti!Thickness(), getRtti!Control(), insetMeta);

        // The corners change nothing about how much room anything needs.
        PropertyMetadata radiusMeta;
        radiusMeta.defaultValue = Value(0.0f);
        radiusMeta.affectsRender = true;

        cornerRadiusProperty = Property.register("CornerRadius",
            getRtti!float(), getRtti!Control(), radiusMeta, &isUsableRadius);

        // What a control is for: being used.  Element says no because most of
        // the tree is structure and a Tab stopping on every panel would be a
        // Tab nobody could use; from here down the answer is yes, which is
        // exactly the division WPF draws between UIElement and Control.
        PropertyMetadata focusableMeta;
        focusableMeta.defaultValue = Value(true);

        focusableProperty.overrideMetadata(getRtti!Control(), focusableMeta);

        // Unset means the plain ring, made per element when it is first needed
        // -- the same rule as the brushes above, and forced by the same thing:
        // a Pen is a CherryObject and a module constructor cannot build one.
        PropertyMetadata penMeta;
        penMeta.defaultValue = Value.init;
        penMeta.affectsRender = true;

        focusPenProperty = Property.register("FocusPen",
            getRtti!Pen(), getRtti!Control(), penMeta);
    }

    static immutable(Property) backgroundProperty;
    static immutable(Property) borderBrushProperty;
    static immutable(Property) borderThicknessProperty;
    static immutable(Property) paddingProperty;
    static immutable(Property) cornerRadiusProperty;
    static immutable(Property) focusPenProperty;

   /**
    * What the ring showing the keyboard is drawn with, or unset for the plain
    * one.
    *
    * The knob a theme reaches for -- and the reason Pen is an object with
    * properties rather than only the struct the drawing model takes.  Unset is
    * not "no ring": it means the default, a hairline of dots inside the border.
    * A pen with no brush is how to ask for no ring at all.
    */
    @property Pen focusPen() const
    {
        auto value = getValue(focusPenProperty);
        return value.empty ? null : value.get!Pen;
    }

    /// ditto
    @property void focusPen(Pen value)
    {
        setValue(focusPenProperty, Value(value));
    }

   /**
    * What fills the control behind its content, or null for nothing.
    *
    * Null is not the same as a transparent brush and the difference shows in
    * two places: nothing is drawn at all, and -- once a panel with no
    * background stops catching clicks -- nothing is hit either.
    */
    @property Brush background() const
    {
        return brushOf(backgroundProperty);
    }

    /// ditto
    @property void background(Brush value)
    {
        setValue(backgroundProperty, Value(value));
    }

    /// What the border is drawn with, or null for no border however thick.
    @property Brush borderBrush() const
    {
        return brushOf(borderBrushProperty);
    }

    /// ditto
    @property void borderBrush(Brush value)
    {
        setValue(borderBrushProperty, Value(value));
    }

   /**
    * How thick the border is on each side.
    *
    * Per side, and the two cases are drawn differently on purpose -- see
    * onRender.  Equal on all four sides is the case that keeps its corners.
    */
    @property Thickness borderThickness() const
    {
        return getValue(borderThicknessProperty).get!Thickness;
    }

    /// ditto
    @property void borderThickness(Thickness value)
    {
        setValue(borderThicknessProperty, Value(value));
    }

    /// Room kept clear between the border and the content.
    @property Thickness padding() const
    {
        return getValue(paddingProperty).get!Thickness;
    }

    /// ditto
    @property void padding(Thickness value)
    {
        setValue(paddingProperty, Value(value));
    }

   /**
    * How far the corners are cut, as a radius in device-independent units.
    *
    * One number, so all four corners match and they are round rather than
    * elliptical.  Four different corners need a geometry, and that arrives with
    * Border.
    */
    @property float cornerRadius() const
    {
        return getValue(cornerRadiusProperty).get!float;
    }

    /// ditto
    @property void cornerRadius(float value)
    {
        setValue(cornerRadiusProperty, Value(value));
    }

   /**
    * What the border and the padding take out of the control before the
    * content sees any of it.
    */
    @property Thickness contentInset() const
    {
        immutable border = borderThickness;
        immutable inner = padding;

        return Thickness(border.left + inner.left, border.top + inner.top,
                         border.right + inner.right, border.bottom + inner.bottom);
    }

protected:
   /**
    * Offers the content what is left after the border and the padding, and
    * asks for that much back plus the two of them.
    *
    * A single-cell container, like the plain Element it derives from -- what a
    * control is until a template gives it a shape.
    */
    override Size measureOverride(Size availableSize)
    {
        immutable inset = contentInset;

        immutable inner = Size(atLeastZero(availableSize.width - inset.horizontal),
                               atLeastZero(availableSize.height - inset.vertical));

        Size content;
        auto view = children;

        foreach (i; 0 .. view.length)
        {
            auto child = view[i];
            child.measure(inner);

            immutable wanted = child.desiredSize;
            if (wanted.width > content.width)
                content.width = wanted.width;
            if (wanted.height > content.height)
                content.height = wanted.height;
        }

        return Size(content.width + inset.horizontal, content.height + inset.vertical);
    }

    /// Places the content inside the border and the padding.
    override Size arrangeOverride(Size finalSize)
    {
        immutable inset = contentInset;

        immutable inner = Rect(inset.left, inset.top,
                               atLeastZero(finalSize.width - inset.horizontal),
                               atLeastZero(finalSize.height - inset.vertical));

        auto view = children;

        foreach (i; 0 .. view.length)
            view[i].arrange(inner);

        return finalSize;
    }

   /**
    * Paints the fill and then the border, in the control's own space.
    *
    * The border is **filled, not stroked**, whenever its sides differ -- and
    * that is not a shortcut.  A stroke is one width by definition, so it cannot
    * express a heavier bottom than top; and a stroke straddles the line it is
    * given, putting half its width outside the rectangle and therefore outside
    * the room the layout granted.  Four filled bands sit exactly where they are
    * told.
    *
    * The one case worth stroking is a border of equal thickness with rounded
    * corners, because four bands have no corners to round.  There the rectangle
    * is pulled in by half the width so the stroke lands inside the control, and
    * the radius follows it in, since the radius given is the one of the outer
    * edge.
    *
    * A border of differing thickness therefore **ignores CornerRadius**.  It is
    * a real limit rather than an oversight: rounded and uneven at once needs a
    * geometry filled by the even-odd rule, which arrives with Border.
    */
    override void onRender(DrawingContext context)
    {
        immutable bounds = Rect(0, 0, actualWidth, actualHeight);
        if (bounds.empty)
            return;

        // Last, over the fill and the border alike: it is a mark on top of the
        // control rather than part of it, which is also why it is drawn from a
        // scope(exit) -- every way out of the border code below is a return.
        scope (exit)
        {
            if (isFocused)
                renderFocusVisual(context);
        }

        immutable radius = cornerRadius;

        if (auto fill = background)
        {
            if (radius > 0)
                context.fillRoundedRectangle(bounds, radius, radius, fill);
            else
                context.fillRectangle(bounds, fill);
        }

        auto edge = borderBrush;
        if (edge is null)
            return;

        immutable border = borderThickness;
        if (!(border.left > 0) && !(border.top > 0) && !(border.right > 0) && !(border.bottom > 0))
            return;

        if (border.left == border.top && border.top == border.right && border.right == border.bottom)
        {
            immutable width = border.left;
            immutable half = width / 2;

            immutable line = Rect(half, half,
                                  bounds.width - width, bounds.height - width);
            if (line.empty)
                return;

            if (radius > 0)
            {
                immutable inner = atLeastZero(radius - half);
                context.drawRoundedRectangle(line, inner, inner, Stroke(edge, width));
            }
            else
            {
                context.drawRectangle(line, Stroke(edge, width));
            }

            return;
        }

        // Top and bottom run the full width; the sides fill what is left
        // between them, so no band overlaps another.
        immutable middle = atLeastZero(bounds.height - border.top - border.bottom);

        if (border.top > 0)
            context.fillRectangle(Rect(0, 0, bounds.width, border.top), edge);
        if (border.bottom > 0)
            context.fillRectangle(Rect(0, bounds.height - border.bottom,
                                       bounds.width, border.bottom), edge);
        if (border.left > 0)
            context.fillRectangle(Rect(0, border.top, border.left, middle), edge);
        if (border.right > 0)
            context.fillRectangle(Rect(bounds.width - border.right, border.top,
                                       border.right, middle), edge);
    }

   /**
    * Draws the ring that says the keyboard is here, inside the border.
    *
    * Its own method rather than part of onRender, because a control that draws
    * something else entirely still wants this and should not have to reproduce
    * it -- and because when templates arrive this is the piece that becomes an
    * adorner rather than moving into one.
    *
    * Inside the border and inset by one, which is where every toolkit puts it:
    * a ring on the border itself reads as part of the border, and a ring
    * outside the control belongs to the layout of whatever is next to it.
    */
    void renderFocusVisual(DrawingContext context)
    {
        auto pen = focusPen;
        if (pen is null)
            pen = defaultFocusPen();

        auto stroke = pen.stroke;
        if (stroke.paint is null || !(stroke.thickness > 0))
            return;

        immutable border = borderThickness;
        immutable half = stroke.thickness / 2;
        immutable inset = 1 + half;

        immutable ring = Rect(border.left + inset, border.top + inset,
                              actualWidth - border.horizontal - inset * 2,
                              actualHeight - border.vertical - inset * 2);
        if (ring.empty)
            return;

        immutable radius = cornerRadius;

        if (radius > 0)
        {
            immutable inner = atLeastZero(radius - border.left - inset);
            context.drawRoundedRectangle(ring, inner, inner, stroke);
        }
        else
        {
            context.drawRectangle(ring, stroke);
        }
    }

   /**
    * A click puts the keyboard here.
    *
    * Not marked handled: taking the focus is not dealing with the press, and a
    * control that also wants to act on it -- every button -- calls super first
    * and then does so.  That ordering is why the hooks are documented as
    * "override and call super first".
    */
    override void handleMouseDown(RoutedEventArgs args)
    {
        super.handleMouseDown(args);

        auto mouse = cast(MouseEventArgs) args;
        if (mouse is null || mouse.button != MouseButton.left)
            return;

        if (focusable && !isFocused)
            focus();
    }

   /**
    * The ring appears and disappears with the keyboard.
    *
    * Asked for by hand because IsFocused deliberately carries no affectsRender:
    * most elements look identical focused and not, and a control that does
    * change says so -- which is this saying so.
    */
    override void handleGotFocus(RoutedEventArgs args)
    {
        super.handleGotFocus(args);
        invalidateVisual();
    }

    /// ditto
    override void handleLostFocus(RoutedEventArgs args)
    {
        super.handleLostFocus(args);
        invalidateVisual();
    }

private:
   /*
    * The ring nobody chose: a hairline of black dots.
    *
    * Made once per control and kept, for the reason every brush in the example
    * is: a Pen is an object with properties, and one per frame would be one
    * per frame.  It cannot be shared between controls through a static either
    * -- a CherryObject binds to the dispatcher of the thread that built it.
    *
    * The square dash cap is load-bearing: a dot is a dash of zero length, so a
    * dotted line with flat caps draws nothing at all.  See DashStyle.
    */
    Pen defaultFocusPen()
    {
        if (_defaultFocusPen is null)
        {
            _defaultFocusPen = new Pen(new SolidColorBrush(Color.black), 1);
            _defaultFocusPen.dashStyle = DashStyle.dot;
            _defaultFocusPen.dashCap = LineCap.square;
        }

        return _defaultFocusPen;
    }

    Pen _defaultFocusPen;

protected:

private:
    Brush brushOf(immutable(Property) property) const
    {
        auto value = getValue(property);
        return value.empty ? null : value.get!Brush;
    }
}

/*
 * A length a subtraction may have driven below zero.  element.d has the same
 * helper and keeps it module-private, which is the rule this package inherits:
 * a control does not reach into the machinery, it repeats the one line.
 */
private float atLeastZero(float value) pure nothrow @nogc
{
    return value > 0 ? value : 0;
}

/*
 * A radius is a length: zero is square, and neither a negative, an infinity nor
 * a NaN is a corner.  Refused at the assignment so that the fault names itself
 * rather than arriving as a shape Direct2D declines to draw.
 */
private bool isUsableRadius(const(Value) value)
{
    immutable radius = value.get!float;
    return radius >= 0 && radius < float.infinity;
}

version (unittest)
{
    import cherry.platform.render : Color, Point, RecordingContext;
    import cherry.ui.media.brush : SolidColorBrush;

    import std.exception : assertThrown;

   /*
    * A child with a size of its own, pinned to the near corner.
    *
    * Pinned on purpose: these tests are about where the inset puts the content,
    * and stretch cannot stretch a child that has both dimensions of its own, so
    * it centres it instead.  A fixture left at the default would have every
    * placement test reading the centring and calling it the padding.
    */
    private class Box : Element
    {
        this(float w, float h)
        {
            width = w;
            height = h;
            horizontalAlignment = HorizontalAlignment.left;
            verticalAlignment = VerticalAlignment.top;
        }
    }

    /// Lays a control out and gives back what it drew.
    private RecordingContext paint(Control control, float w, float h)
    {
        control.measure(Size(w, h));
        control.arrange(Rect(0, 0, w, h));

        auto context = new RecordingContext;
        control.renderSubtree(context);
        return context;
    }
}

unittest
{
    // The border and the padding both take room away from the content, and the
    // control asks its parent for the content plus the two of them.
    auto control = new Control;
    control.borderThickness = Thickness(2);
    control.padding = Thickness(10, 5);

    auto box = new Box(40, 20);
    control.addChild(box);

    control.measure(Size(500, 400));
    assert(control.desiredSize == Size(40 + 24, 20 + 14),
           "ten of padding and two of border on each side, and the box between them");

    control.arrange(Rect(0, 0, 500, 400));
    assert(box.arrangedRect == Rect(12, 7, 40, 20),
           "in by the border and the padding, and no further");

    // And with neither, it is the plain single-cell container it derives from.
    auto bare = new Control;
    bare.addChild(new Box(40, 20));
    bare.measure(Size(500, 400));
    assert(bare.desiredSize == Size(40, 20));
}

unittest
{
    // Nothing to paint with means nothing painted -- not a transparent fill,
    // and not a border of no colour.
    auto control = new Control;
    control.borderThickness = Thickness(4);

    auto context = paint(control, 100, 50);
    assert(context.entries.length == 0, "no brushes, no marks");

    control.background = new SolidColorBrush(Color.white);
    assert(paint(control, 100, 50).entries.length == 1, "the fill, and still no border");
}

unittest
{
    // A border of one thickness keeps its corners, so it is stroked -- pulled
    // in by half its width so that it lands inside the control rather than
    // straddling the edge and spilling out of the slot the layout gave it.
    auto control = new Control;
    control.borderBrush = new SolidColorBrush(Color.black);
    control.borderThickness = Thickness(4);

    auto context = paint(control, 100, 50);

    assert(context.entries.length == 1);

    auto entry = context.entries[0];
    assert(entry.kind == RecordingContext.Kind.drawRectangle);
    assert(entry.stroke.thickness == 4);
    assert(entry.rect == Rect(2, 2, 96, 46), "in by half, so the stroke ends at the edge");

    // With a radius it is the rounded stroke instead, and the radius follows
    // the line inwards, because the one given describes the outer edge.
    control.cornerRadius = 6;
    auto rounded = paint(control, 100, 50);

    assert(rounded.entries[0].kind == RecordingContext.Kind.drawRoundedRectangle);
    assert(rounded.entries[0].radiusX == 4 && rounded.entries[0].radiusY == 4);
}

unittest
{
    // A border that differs from side to side cannot be a stroke -- a stroke is
    // one width -- so it is four bands, and the corners go with it.
    auto control = new Control;
    control.borderBrush = new SolidColorBrush(Color.black);
    control.borderThickness = Thickness(1, 2, 3, 4);
    control.cornerRadius = 8;

    auto context = paint(control, 100, 50);

    assert(context.entries.length == 4, "top, bottom, left, right");

    foreach (entry; context.entries)
        assert(entry.kind == RecordingContext.Kind.fillRectangle,
               "filled, so that every band sits exactly where it was put");

    assert(context.entries[0].rect == Rect(0, 0, 100, 2), "the top runs the full width");
    assert(context.entries[1].rect == Rect(0, 46, 100, 4), "and so does the bottom");
    assert(context.entries[2].rect == Rect(0, 2, 1, 44), "the sides fill between them");
    assert(context.entries[3].rect == Rect(97, 2, 3, 44));

    // A side of no thickness draws nothing at all.
    control.borderThickness = Thickness(0, 2, 0, 0);
    auto oneSided = paint(control, 100, 50);
    assert(oneSided.entries.length == 1 && oneSided.entries[0].rect == Rect(0, 0, 100, 2));
}

unittest
{
    // A radius is a length, and the refusal leaves what was there alone.
    auto control = new Control;

    control.cornerRadius = 4;
    assert(control.cornerRadius == 4);

    assertThrown(control.setValue(Control.cornerRadiusProperty, Value(-1.0f)));
    assertThrown(control.setValue(Control.cornerRadiusProperty, Value(float.infinity)));
    assertThrown(control.setValue(Control.cornerRadiusProperty, Value(float.nan)));
    assert(control.cornerRadius == 4);
}

unittest
{
    // A control takes the keyboard where a plain element does not.
    auto control = new Control;
    assert(control.focusable, "which is most of what being a control means");
    assert(control.isTabStop);

    auto plain = new Element;
    assert(!plain.focusable, "and structure still does not");
}

unittest
{
    import cherry.platform.render : RecordingContext;
    import cherry.ui.testing : makeWindow;

    // The ring is drawn only while the keyboard is here, inside the border,
    // and with the pen the control was given.
    auto w = makeWindow();

    auto control = new Control;
    control.width = 100;
    control.height = 40;
    control.horizontalAlignment = HorizontalAlignment.left;
    control.verticalAlignment = VerticalAlignment.top;
    control.borderThickness = Thickness(2);
    control.borderBrush = new SolidColorBrush(Color.black);

    w.window.addChild(control);
    w.window.updateLayout();

    auto before = new RecordingContext;
    control.renderSubtree(before);
    immutable unfocused = before.entries.length;

    control.focus();
    assert(control.isFocused);

    auto after = new RecordingContext;
    control.renderSubtree(after);

    assert(after.entries.length == unfocused + 1, "one more thing drawn, and only one");

    auto ring = after.entries[$ - 1];
    assert(ring.kind == RecordingContext.Kind.drawRectangle);
    assert(ring.stroke.dashStyle == DashStyle.dot, "dotted, the way a focus ring is");
    assert(ring.stroke.dashCap == LineCap.square,
           "and with a cap, or a dot of zero length would draw nothing");

    // Inside the 2-wide border, inset by one, and pulled in by half the stroke.
    assert(ring.rect == Rect(3.5f, 3.5f, 93, 33));

    control.unfocus();

    auto gone = new RecordingContext;
    control.renderSubtree(gone);
    assert(gone.entries.length == unfocused, "and it goes when the keyboard does");
}

unittest
{
    import cherry.platform.render : RecordingContext;
    import cherry.ui.testing : makeWindow;

    // The pen is a property, so a theme can replace the ring -- and a pen with
    // no brush is how to ask for no ring at all.
    auto w = makeWindow();

    auto control = new Control;
    control.width = 100;
    control.height = 40;
    control.horizontalAlignment = HorizontalAlignment.left;
    control.verticalAlignment = VerticalAlignment.top;
    w.window.addChild(control);
    w.window.updateLayout();
    control.focus();

    auto own = new Pen(new SolidColorBrush(Color.white), 3);
    control.focusPen = own;

    auto context = new RecordingContext;
    control.renderSubtree(context);

    assert(context.entries.length == 1);
    assert(context.entries[0].stroke.thickness == 3);
    assert(context.entries[0].stroke.dashStyle == DashStyle.solid, "this one is not dotted");

    control.focusPen = new Pen;   // no brush: nothing to draw with

    auto silent = new RecordingContext;
    control.renderSubtree(silent);
    assert(silent.entries.length == 0);
}

unittest
{
    import cherry.ui.input : onMouseDown;
    import cherry.ui.testing : makeWindow;

    // Clicking puts the keyboard on the control, and does not claim the press
    // while doing it -- a control that also acts on the click still can.
    auto w = makeWindow();

    auto control = new Control;
    control.width = 100;
    control.height = 40;
    control.horizontalAlignment = HorizontalAlignment.left;
    control.verticalAlignment = VerticalAlignment.top;
    w.window.addChild(control);
    w.window.updateLayout();

    int windowHeard;
    w.window.onMouseDown ~= (Element sender, RoutedEventArgs args) { ++windowHeard; };

    w.platform.host.onMouseDown(MouseButton.left, 50, 20);

    assert(control.isFocused);
    assert(windowHeard == 1, "taking the focus is not dealing with the press");

    // The right button is not how anything is focused.
    control.unfocus();
    w.platform.host.onMouseDown(MouseButton.right, 50, 20);
    assert(!control.isFocused);
}
