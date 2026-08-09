module cherry.ui.media.brush;

/*
 * A module constructor here is safe, and for the reason the controls package
 * already relies on: the imports of this package run one way.  It imports the
 * styled layer and the drawing model; nothing in either imports it back.
 *
 * The rule this subpackage lives by, same as controls: import downwards only.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : Color, GradientPaint, GradientSpread, GradientStop,
                                Paint, Point, SolidPaint;
import cherry.ui.styledelement;

/**
 * Something to fill a shape with: a colour, a ramp between colours, and later
 * an image or a pattern.
 *
 * **A StyledElement, not an Element.** It has properties, so it can be bound
 * and animated; it sits on the logical tree, so a brush written inside a
 * control can resolve a binding against that control's data -- and it draws
 * nothing itself, is never laid out, and is never hit.  That is exactly the
 * shape StyledElement was placed low for.
 *
 * WPF puts Brush on a separate branch and then has to bolt an inheritance
 * context onto Freezable to get the binding case back; the difference is that
 * WPF's styled layer carries layout and visuals, and this one carries a parent
 * link and value inheritance.  Avalonia splits it the same way WPF does, for
 * the same reason.
 *
 * The drawing model does not see any of this: it sees the Paint interface,
 * which is the little of a brush a backend can act on.  See render.d for why
 * that seam has to be an interface rather than this class.
 */
abstract class Brush : StyledElement, Paint
{
   /**
    * Changes whenever anything about this brush changes how it looks.
    *
    * A backend caches the device resource it builds from a brush and needs to
    * know when that copy is stale.  Every property write goes through
    * onPropertyChanged, so counting there catches all of them without any
    * property having to remember to say so.
    *
    * Starts at one, so that a cache using zero for "nothing built yet" cannot
    * mistake a brand-new brush for one it has already seen.
    */
    @property ulong revision() const
    {
        return _revision;
    }

protected:
   /**
    * The first use of this hook for something other than layout.
    *
    * A brush has nothing to invalidate -- it does not know who is painted with
    * it, and deliberately: a brush shared by fifty elements would otherwise
    * have to keep fifty back-references alive.  All it does is admit that it
    * has changed, and leave whoever cares to notice.
    */
    override void onPropertyChanged(immutable(Property) property,
                                    ref immutable(PropertyMetadata) metadata,
                                    const(Value) oldValue,
                                    const(Value) newValue)
    {
        super.onPropertyChanged(property, metadata, oldValue, newValue);

        ++_revision;
    }

private:
    ulong _revision = 1;
}

/**
 * One colour everywhere -- the brush almost everything is painted with.
 */
class SolidColorBrush : Brush, SolidPaint
{
    shared static this()
    {
        PropertyMetadata colorMeta;
        colorMeta.defaultValue = Value(Color.black);

        colorProperty = Property.register("Color",
            getRtti!Color(), getRtti!SolidColorBrush(), colorMeta);
    }

    static immutable(Property) colorProperty;

    this()
    {
    }

    /// ditto
    this(Color color)
    {
        this.color = color;
    }

    /// The colour to fill with.  Black until told otherwise.
    @property Color color() const
    {
        return getValue(colorProperty).get!Color;
    }

    /// ditto
    @property void color(Color value)
    {
        setValue(colorProperty, Value(value));
    }
}

/**
 * A ramp between colours -- what the ramp is made of and what happens past its
 * ends.  Where the ramp runs is left to the subclass, because that is the only
 * thing a linear and a radial gradient disagree about.
 */
abstract class GradientBrush : Brush, GradientPaint
{
    shared static this()
    {
        PropertyMetadata stopsMeta;
        stopsMeta.defaultValue = Value(cast(GradientStop[]) null);

        stopsProperty = Property.register("Stops",
            getRtti!(GradientStop[])(), getRtti!GradientBrush(), stopsMeta);

        PropertyMetadata spreadMeta;
        spreadMeta.defaultValue = Value(GradientSpread.pad);

        spreadProperty = Property.register("Spread",
            getRtti!GradientSpread(), getRtti!GradientBrush(), spreadMeta);
    }

    static immutable(Property) stopsProperty;
    static immutable(Property) spreadProperty;

   /**
    * The colours of the ramp and how far along each sits.
    *
    * An ordinary property although it holds an array, because a Value compares
    * a dynamic array by its contents: assigning a different array of the same
    * stops is correctly not a change, so it does not bump the revision and does
    * not throw away a cached device resource.
    *
    * Empty by default, which paints nothing.  A gradient with no colours has
    * nothing to say, and inventing two would be inventing a look.
    */
    @property const(GradientStop)[] stops() const
    {
        return getValue(stopsProperty).get!(GradientStop[]);
    }

    /// ditto
    @property void stops(GradientStop[] value)
    {
        setValue(stopsProperty, Value(value));
    }

    /// What the gradient does outside the span between its ends.
    @property GradientSpread spread() const
    {
        return getValue(spreadProperty).get!GradientSpread;
    }

    /// ditto
    @property void spread(GradientSpread value)
    {
        setValue(spreadProperty, Value(value));
    }
}

/**
 * A ramp along a straight line.
 *
 * The ends are fractions of whatever is being filled, so the defaults -- (0, 0)
 * to (0, 1) -- mean top to bottom at any size.  That is the direction almost
 * every button, header and panel is shaded in, and it is the one a control can
 * ask for without knowing how big the layout will make it.
 */
class LinearGradientBrush : GradientBrush
{
    shared static this()
    {
        PropertyMetadata startMeta;
        startMeta.defaultValue = Value(Point(0, 0));

        startPointProperty = Property.register("StartPoint",
            getRtti!Point(), getRtti!LinearGradientBrush(), startMeta);

        PropertyMetadata endMeta;
        endMeta.defaultValue = Value(Point(0, 1));

        endPointProperty = Property.register("EndPoint",
            getRtti!Point(), getRtti!LinearGradientBrush(), endMeta);
    }

    static immutable(Property) startPointProperty;
    static immutable(Property) endPointProperty;

    this()
    {
    }

   /**
    * The two-colour case, which is most of them: from one colour at the start
    * of the ramp to another at its end.
    */
    this(Color from, Color to)
    {
        stops = [GradientStop(0, from), GradientStop(1, to)];
    }

    /// Where the ramp begins and ends, as fractions of what is being filled.
    @property Point start() const
    {
        return getValue(startPointProperty).get!Point;
    }

    /// ditto
    @property void start(Point value)
    {
        setValue(startPointProperty, Value(value));
    }

    /// ditto
    @property Point end() const
    {
        return getValue(endPointProperty).get!Point;
    }

    /// ditto
    @property void end(Point value)
    {
        setValue(endPointProperty, Value(value));
    }
}

unittest
{
    // A brush with nothing said about it, and the revision that a cache reads.
    auto brush = new SolidColorBrush;

    assert(brush.color == Color.black);
    assert(brush.revision == 1, "not zero, which is what a cache means by nothing built yet");

    immutable was = brush.revision;
    brush.color = Color.white;
    assert(brush.color == Color.white);
    assert(brush.revision > was, "a different look is a different revision");

    // Writing the same value again is not a change, so nothing downstream has
    // to rebuild anything.
    immutable settled = brush.revision;
    brush.color = Color.white;
    assert(brush.revision == settled);

    assert(new SolidColorBrush(Color.rgb(1, 0, 0)).color == Color.rgb(1, 0, 0));
}

unittest
{
    // A gradient says where it runs, what it is made of, and what happens past
    // the ends.
    auto brush = new LinearGradientBrush(Color.rgb(1, 0, 0), Color.rgb(0, 0, 1));

    assert(brush.start == Point(0, 0) && brush.end == Point(0, 1), "top to bottom");
    assert(brush.spread == GradientSpread.pad);

    assert(brush.stops.length == 2);
    assert(brush.stops[0] == GradientStop(0, Color.rgb(1, 0, 0)));
    assert(brush.stops[1] == GradientStop(1, Color.rgb(0, 0, 1)));

    // Every property of a gradient moves the revision, not just the colours.
    immutable was = brush.revision;
    brush.end = Point(1, 0);
    assert(brush.revision > was);

    immutable moved = brush.revision;
    brush.spread = GradientSpread.reflect;
    assert(brush.revision > moved);

    // The same ramp given again is the same ramp: a dynamic array in a Value
    // compares by content, so nothing downstream is asked to rebuild.
    immutable settled = brush.revision;
    brush.stops = [GradientStop(0, Color.rgb(1, 0, 0)), GradientStop(1, Color.rgb(0, 0, 1))];
    assert(brush.revision == settled);

    auto bare = new LinearGradientBrush;
    assert(bare.stops.length == 0, "no colours means nothing to paint, not a guess");
}

unittest
{
    // What a brush is a StyledElement for: it sits on the logical tree and
    // inherits from it, which is how a binding written inside a control will
    // reach that control's data.
    //
    // Nothing builds such a tree yet -- markup will -- so the parent is stood
    // up by hand here, exactly as styledelement.d's own test does.
    static class Owned : SolidColorBrush
    {
        StyledElement above;

        override @property inout(StyledElement) logicalParent() inout
        {
            return above;
        }
    }

    // Registered on the brush's own line, and that matters: registerCore keeps
    // only the default *value* in the property's bare metadata and attaches the
    // flags as an override on the owner type.  So `inherits` applies to readers
    // that reach the owner through their class chain and to nobody else --
    // register this on some unrelated class and the brush would read the
    // default forever, with nothing to say why.
    PropertyMetadata meta;
    meta.defaultValue = Value(10);
    meta.inherits = true;
    auto accent = Property.register("BrushInheritedAccent",
        getRtti!int(), getRtti!Owned(), meta);

    auto host = new StyledElement;
    auto brush = new Owned;
    brush.above = host;

    assert(brush.getValue(accent).get!int == 10);

    // The holder needs no metadata of its own: what travels down is the value
    // in its store, and it is the reader's metadata that says to look.
    host.setValue(accent, Value(42));
    assert(brush.getValue(accent).get!int == 42,
           "the brush reads what the thing it was written inside says");

    brush.above = null;
    assert(brush.getValue(accent).get!int == 10, "cut off from the tree, cut off from the value");
}

unittest
{
    // A brush is what a drawing context is handed, and the whole of what the
    // drawing model can see of it is the Paint side.  This is that seam read
    // from the outside: the model's vocabulary, answered by the object's.
    import cherry.platform.render : RecordingContext, Rect;

    auto flat = new SolidColorBrush(Color.rgb(0.2, 0.4, 0.6));
    auto ramp = new LinearGradientBrush(Color.rgb(1, 0, 0), Color.rgb(0, 0, 1));
    ramp.end = Point(1, 0);
    ramp.spread = GradientSpread.repeat;

    auto context = new RecordingContext;
    context.fillRectangle(Rect(0, 0, 100, 50), flat);
    context.fillRectangle(Rect(0, 0, 100, 50), ramp);

    // A flat paint resolves to its colour, which is what almost every test
    // wants to read.
    assert(context.entries[0].color == Color.rgb(0.2, 0.4, 0.6));
    assert(cast(SolidPaint) context.entries[0].paint !is null);

    // A gradient has no one colour, so it says so and is read through its own
    // side of the seam.
    assert(context.entries[1].color == Color.transparent,
           "no single colour stands for a ramp");

    auto seen = cast(GradientPaint) context.entries[1].paint;
    assert(seen !is null);
    assert(seen.start == Point(0, 0) && seen.end == Point(1, 0), "left to right");
    assert(seen.spread == GradientSpread.repeat);
    assert(seen.stops.length == 2 && seen.stops[1].color == Color.rgb(0, 0, 1));
    assert(seen.revision == ramp.revision);
}
