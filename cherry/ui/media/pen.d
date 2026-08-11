module cherry.ui.media.pen;

/*
 * A module constructor here is safe for the reason brush.d's banner spells out:
 * the imports of this package run one way.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : DashStyle, LineCap, LineJoin, Stroke;
import cherry.ui.media.brush : Brush;
import cherry.ui.styledelement;

/**
 * What a line is drawn with: a brush to colour it, a width, and the shape of
 * its ends, its corners and its dashes.
 *
 * **The object half of a Stroke**, and the split is the same one TextBlock
 * makes with TextFormat.  The parts live here as properties so they can be
 * bound, styled and animated; the whole is assembled into a plain struct at the
 * moment of drawing, because a drawing call happens once a frame and must not
 * cost an allocation -- let alone the allocation of a CherryObject, which binds
 * itself to a dispatcher on the way up.
 *
 * A StyledElement for exactly the reasons Brush is one: properties, a place on
 * the logical tree so a binding written inside a control resolves against it,
 * and nothing else.  See brush.d.
 *
 * Note what is **not** here: `stroke` reads the properties every time it is
 * called and keeps nothing, so a pen has no revision and nothing caches it.
 * What a backend caches is keyed by the shape the struct describes, which is a
 * handful of enum members shared by everything drawing the same kind of line.
 */
class Pen : StyledElement
{
    shared static this()
    {
        // Unset, not a black brush.  Same rule as Control.Background and for
        // the same reason: a brush is a CherryObject and a module constructor
        // is far too early to build one.  A pen with no brush draws nothing,
        // which is the honest reading of "nobody said what colour".
        PropertyMetadata brushMeta;
        brushMeta.defaultValue = Value.init;

        brushProperty = Property.register("brush",
            getRtti!Brush(), getRtti!Pen(), brushMeta);

        PropertyMetadata thicknessMeta;
        thicknessMeta.defaultValue = Value(1.0f);

        thicknessProperty = Property.register("thickness",
            getRtti!float(), getRtti!Pen(), thicknessMeta);

        PropertyMetadata dashMeta;
        dashMeta.defaultValue = Value(DashStyle.solid);

        dashStyleProperty = Property.register("dashStyle",
            getRtti!DashStyle(), getRtti!Pen(), dashMeta);

        PropertyMetadata capMeta;
        capMeta.defaultValue = Value(LineCap.flat);

        startCapProperty = Property.register("startCap",
            getRtti!LineCap(), getRtti!Pen(), capMeta);
        endCapProperty = Property.register("endCap",
            getRtti!LineCap(), getRtti!Pen(), capMeta);
        dashCapProperty = Property.register("dashCap",
            getRtti!LineCap(), getRtti!Pen(), capMeta);

        PropertyMetadata joinMeta;
        joinMeta.defaultValue = Value(LineJoin.miter);

        lineJoinProperty = Property.register("lineJoin",
            getRtti!LineJoin(), getRtti!Pen(), joinMeta);

        PropertyMetadata miterMeta;
        miterMeta.defaultValue = Value(10.0f);

        miterLimitProperty = Property.register("miterLimit",
            getRtti!float(), getRtti!Pen(), miterMeta);

        PropertyMetadata offsetMeta;
        offsetMeta.defaultValue = Value(0.0f);

        dashOffsetProperty = Property.register("dashOffset",
            getRtti!float(), getRtti!Pen(), offsetMeta);
    }

    static immutable(Property) brushProperty;
    static immutable(Property) thicknessProperty;
    static immutable(Property) dashStyleProperty;
    static immutable(Property) startCapProperty;
    static immutable(Property) endCapProperty;
    static immutable(Property) dashCapProperty;
    static immutable(Property) lineJoinProperty;
    static immutable(Property) miterLimitProperty;
    static immutable(Property) dashOffsetProperty;

    this()
    {
    }

    /// The pen most callers want: something to draw with, and how wide.
    this(Brush brush, float thickness = 1)
    {
        this.brush = brush;
        this.thickness = thickness;
    }

    /// What colours the line, or null for a pen that draws nothing.
    @property Brush brush() const
    {
        auto value = getValue(brushProperty);
        return value.empty ? null : value.get!Brush;
    }

    /// ditto
    @property void brush(Brush value)
    {
        setValue(brushProperty, Value(value));
    }

    /// How wide the line is, in the coordinate space it is drawn in.
    @property float thickness() const
    {
        return getValue(thicknessProperty).get!float;
    }

    /// ditto
    @property void thickness(float value)
    {
        setValue(thicknessProperty, Value(value));
    }

   /**
    * How the line is broken up along its length.
    *
    * A dot is a dash of zero length, so dots want a dashCap that has some
    * extent -- see DashStyle in the drawing model.
    */
    @property DashStyle dashStyle() const
    {
        return getValue(dashStyleProperty).get!DashStyle;
    }

    /// ditto
    @property void dashStyle(DashStyle value)
    {
        setValue(dashStyleProperty, Value(value));
    }

    /// How the line ends, and how each dash in it ends.
    @property LineCap startCap() const
    {
        return getValue(startCapProperty).get!LineCap;
    }

    /// ditto
    @property void startCap(LineCap value)
    {
        setValue(startCapProperty, Value(value));
    }

    /// ditto
    @property LineCap endCap() const
    {
        return getValue(endCapProperty).get!LineCap;
    }

    /// ditto
    @property void endCap(LineCap value)
    {
        setValue(endCapProperty, Value(value));
    }

    /// ditto
    @property LineCap dashCap() const
    {
        return getValue(dashCapProperty).get!LineCap;
    }

    /// ditto
    @property void dashCap(LineCap value)
    {
        setValue(dashCapProperty, Value(value));
    }

    /// Both caps at once, which is what a caller almost always means.
    @property void caps(LineCap value)
    {
        startCap = value;
        endCap = value;
    }

    /// How two segments meet, and how far a mitre may run before it is cut.
    @property LineJoin lineJoin() const
    {
        return getValue(lineJoinProperty).get!LineJoin;
    }

    /// ditto
    @property void lineJoin(LineJoin value)
    {
        setValue(lineJoinProperty, Value(value));
    }

    /// ditto
    @property float miterLimit() const
    {
        return getValue(miterLimitProperty).get!float;
    }

    /// ditto
    @property void miterLimit(float value)
    {
        setValue(miterLimitProperty, Value(value));
    }

    /// Where in the dash pattern the line starts, in thicknesses.
    @property float dashOffset() const
    {
        return getValue(dashOffsetProperty).get!float;
    }

    /// ditto
    @property void dashOffset(float value)
    {
        setValue(dashOffsetProperty, Value(value));
    }

   /**
    * The pen as the drawing model takes it.
    *
    * Read at the moment of drawing and kept nowhere, so a pen whose brush or
    * width changed since the last frame needs no invalidation of its own -- the
    * element that draws with it asks again.
    */
    @property Stroke stroke() const
    {
        Stroke result;

        result.paint = brush;
        result.thickness = thickness;
        result.dashStyle = dashStyle;
        result.startCap = startCap;
        result.endCap = endCap;
        result.dashCap = dashCap;
        result.lineJoin = lineJoin;
        result.miterLimit = miterLimit;
        result.dashOffset = dashOffset;

        return result;
    }
}

unittest
{
    import cherry.ui.media.brush : SolidColorBrush;
    import cherry.platform.render : Color;

    // A pen nobody has shaped draws a hairline the plain way, and says so in
    // the terms the drawing model uses.
    auto pen = new Pen;

    assert(pen.brush is null, "nothing said what colour, so it paints nothing");
    assert(pen.thickness == 1);
    assert(pen.stroke.hasPlainShape);
    assert(pen.stroke.paint is null);

    // The shorthand every caller reaches for.
    auto ink = new SolidColorBrush(Color.black);
    auto plain = new Pen(ink, 2);

    assert(plain.brush is ink);
    assert(plain.stroke.thickness == 2);

    // Compared through the object, not against the class reference: a brush
    // reaches Paint by two routes -- Brush implements it, and SolidPaint
    // extends it -- so the two interface references sit at different offsets
    // inside the same object and `is` between them is false.  cast(Object) is
    // the question actually being asked, and is how the backend keys its cache.
    assert(cast(Object) plain.stroke.paint is ink,
           "the brush reaches the model as a paint");
}

unittest
{
    import cherry.ui.media.brush : SolidColorBrush;
    import cherry.platform.render : Color;

    // Every part reaches the struct, and it is read fresh each time -- a pen
    // changed after a stroke was taken gives a different one next time, which
    // is what lets an element draw with a pen it does not watch.
    auto pen = new Pen(new SolidColorBrush(Color.white), 3);
    pen.dashStyle = DashStyle.dashDot;
    pen.caps = LineCap.round;
    pen.dashCap = LineCap.square;
    pen.lineJoin = LineJoin.bevel;
    pen.miterLimit = 4;
    pen.dashOffset = 1.5f;

    // Not immutable: a Stroke reaches a paint, so it cannot be frozen without
    // freezing the brush behind it.
    auto taken = pen.stroke;

    assert(taken.thickness == 3);
    assert(taken.dashStyle == DashStyle.dashDot);
    assert(taken.startCap == LineCap.round && taken.endCap == LineCap.round);
    assert(taken.dashCap == LineCap.square);
    assert(taken.lineJoin == LineJoin.bevel);
    assert(taken.miterLimit == 4);
    assert(taken.dashOffset == 1.5f);
    assert(!taken.hasPlainShape);

    pen.thickness = 8;
    assert(pen.stroke.thickness == 8, "read again, not remembered");
    assert(taken.thickness == 3, "and what was taken before is a copy, untouched");
}

unittest
{
    // A pen is a styled element and nothing more: it is not in the visual tree,
    // has no size and is never hit, which is the whole reason it can be shared
    // by every element that draws the same line.
    auto pen = new Pen;

    assert(cast(StyledElement) pen !is null);
    assert(pen.logicalParent is null);
}
