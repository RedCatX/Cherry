module cherry.ui.controls.control;

/*
 * A module constructor here is safe for the reason stackpanel.d's banner spells
 * out: the imports of this package run one way.  This one imports the element
 * tree and the media package; nothing in either imports a control.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : DrawingContext, Rect, Size, Thickness;
import cherry.ui.element;
import cherry.ui.media.brush : Brush;

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
    }

    static immutable(Property) backgroundProperty;
    static immutable(Property) borderBrushProperty;
    static immutable(Property) borderThicknessProperty;
    static immutable(Property) paddingProperty;
    static immutable(Property) cornerRadiusProperty;

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

        immutable radius = cornerRadius;

        if (auto fill = background)
        {
            if (radius > 0)
                context.fillRoundedRectangle(bounds, radius, radius, fill);
            else
                context.fillRectangle(bounds, fill);
        }

        auto stroke = borderBrush;
        if (stroke is null)
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
                context.drawRoundedRectangle(line, inner, inner, stroke, width);
            }
            else
            {
                context.drawRectangle(line, stroke, width);
            }

            return;
        }

        // Top and bottom run the full width; the sides fill what is left
        // between them, so no band overlaps another.
        immutable middle = atLeastZero(bounds.height - border.top - border.bottom);

        if (border.top > 0)
            context.fillRectangle(Rect(0, 0, bounds.width, border.top), stroke);
        if (border.bottom > 0)
            context.fillRectangle(Rect(0, bounds.height - border.bottom,
                                       bounds.width, border.bottom), stroke);
        if (border.left > 0)
            context.fillRectangle(Rect(0, border.top, border.left, middle), stroke);
        if (border.right > 0)
            context.fillRectangle(Rect(bounds.width - border.right, border.top,
                                       border.right, middle), stroke);
    }

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
    assert(entry.strokeWidth == 4);
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
