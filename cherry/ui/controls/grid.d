module cherry.ui.controls.grid;

/*
 * A module constructor here is safe for the reason stackpanel.d's banner spells
 * out: the imports of this package run one way.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.ui.styledelement;

/**
 * What kind of length a track was given.
 *
 * `auto_` carries the underscore because `auto` is a keyword in D -- the same
 * escape `Key.delete_` already uses.  It is rarely typed: `GridLength.autoSize`
 * is how a caller says it.
 */
enum GridUnitType
{
    /// Exactly this many device-independent units.
    pixel,
    /// As much as the content in it needs, and no more.
    auto_,
    /// A share of whatever is left once the other two have had theirs.
    star
}

/**
 * How long a row or a column is: a number and what the number means.
 *
 * Three kinds, and the difference between them is *when* the length is known.
 * A pixel length is known before anything is measured.  An auto length is known
 * once the content has been measured.  A star length is known only once both of
 * those are settled and there is a remainder to divide -- which is why a star
 * with nothing to divide (an unbounded offer) is measured as an auto instead.
 *
 * `GridLength.init` is zero pixels, while a definition's Length **defaults to
 * one star**.  They disagree on purpose, exactly as `Orientation.init` and
 * StackPanel's default do: a track nobody described should share out the room,
 * but a bare GridLength variable has to start somewhere and zero is the only
 * honest place.
 *
 * A plain struct, so it can be a property value: it holds a float and an enum
 * and reaches nothing, which is what the property system compares byte for byte.
 */
struct GridLength
{
   /**
    * A fixed length, in the same device-independent units as everything else.
    */
    this(float pixels) pure nothrow @nogc
    {
        _value = pixels;
        _type = GridUnitType.pixel;
    }

    /// As much as the content needs.
    static GridLength autoSize() pure nothrow @nogc
    {
        GridLength result;
        result._type = GridUnitType.auto_;
        return result;
    }

   /**
    * A share of the remainder, weighed against the other stars.
    *
    * Two columns of `star(1)` and `star(2)` divide what is left one part to
    * two.  The weights are relative and nothing else: `star(1)` and `star(100)`
    * beside each other behave identically to `star(1)` and `star(100)` scaled
    * however one likes.
    */
    static GridLength star(float weight = 1) pure nothrow @nogc
    {
        GridLength result;
        result._value = weight;
        result._type = GridUnitType.star;
        return result;
    }

    @property float value() pure const nothrow @nogc
    {
        return _value;
    }

    @property GridUnitType unitType() pure const nothrow @nogc
    {
        return _type;
    }

    @property bool isAbsolute() pure const nothrow @nogc
    {
        return _type == GridUnitType.pixel;
    }

    /// ditto
    @property bool isAuto() pure const nothrow @nogc
    {
        return _type == GridUnitType.auto_;
    }

    /// ditto
    @property bool isStar() pure const nothrow @nogc
    {
        return _type == GridUnitType.star;
    }

private:
    float        _value = 0;
    GridUnitType _type = GridUnitType.pixel;
}

/**
 * One row or one column: how long it is, what it may not be shorter or longer
 * than, and -- once the grid has worked it out -- how long it turned out to be.
 *
 * **A StyledElement**, for the reasons Brush and Pen are: it has properties, so
 * it can be bound and animated, and it sits on the logical tree, so a binding
 * written inside a definition resolves against the grid that owns it.  It draws
 * nothing, is never laid out and is never hit.
 *
 * **The properties are named for neither axis**, and the axis-specific readings
 * are plain aliases on the two subclasses.  That is what lets the sizing code be
 * written once and used for both: it works on DefinitionBase and never learns
 * which way it is pointing.  The cost is that a binding names `Length` where a
 * reader would write `column.width`, which is worth saying out loud and is not
 * worth two parallel sets of properties.
 */
class DefinitionBase : StyledElement
{
    shared static this()
    {
        // One star: a track nobody described takes a share of the room.  See
        // GridLength for why the struct's own init is not this.
        PropertyMetadata lengthMeta;
        lengthMeta.defaultValue = Value(GridLength.star(1));

        lengthProperty = Property.register("Length",
            getRtti!GridLength(), getRtti!DefinitionBase(), lengthMeta, &isUsableLength);

        // Zero and infinity, which are the two lengths that change nothing --
        // the same pair, and the same reasoning, as Element's MinWidth/MaxWidth.
        PropertyMetadata minMeta;
        minMeta.defaultValue = Value(0.0f);

        minLengthProperty = Property.register("MinLength",
            getRtti!float(), getRtti!DefinitionBase(), minMeta, &isUsableBound);

        PropertyMetadata maxMeta;
        maxMeta.defaultValue = Value(float.infinity);

        maxLengthProperty = Property.register("MaxLength",
            getRtti!float(), getRtti!DefinitionBase(), maxMeta, &isUsableBound);

        // Written by the grid's sizing pass and by nothing else, so it takes a
        // key -- and the key never leaves this module.
        PropertyMetadata actualMeta;
        actualMeta.defaultValue = Value(0.0f);

        actualLengthKey = Property.registerReadOnly("ActualLength",
            getRtti!float(), getRtti!DefinitionBase(), actualMeta);
    }

    static immutable(Property) lengthProperty;
    static immutable(Property) minLengthProperty;
    static immutable(Property) maxLengthProperty;

   /**
    * How long the track asks to be.  One star until told otherwise.
    */
    @property GridLength length() const
    {
        return getValue(lengthProperty).get!GridLength;
    }

    /// ditto
    @property void length(GridLength value)
    {
        setValue(lengthProperty, Value(value));
    }

   /**
    * The bounds the track is held between, whatever its length asks for.
    *
    * They apply to every kind: a pixel track is clamped by them, an auto track
    * cannot shrink below the minimum however little its content needs, and a
    * star track that would be given more than its maximum takes the maximum and
    * leaves the rest to the other stars.
    */
    @property float minLength() const
    {
        return getValue(minLengthProperty).get!float;
    }

    /// ditto
    @property void minLength(float value)
    {
        setValue(minLengthProperty, Value(value));
    }

    /// ditto
    @property float maxLength() const
    {
        return getValue(maxLengthProperty).get!float;
    }

    /// ditto
    @property void maxLength(float value)
    {
        setValue(maxLengthProperty, Value(value));
    }

   /**
    * How long the track actually turned out to be, after the last layout.
    *
    * Zero until the grid has laid out at least once.  Read-only, and the key
    * stays in this module: what a track ended up as is the grid's answer, not
    * something anyone may assert.
    */
    static @property immutable(Property) actualLengthProperty() pure nothrow
    {
        return actualLengthKey.property;
    }

    /// ditto
    @property float actualLength() const
    {
        return getValue(actualLengthProperty).get!float;
    }

   /**
    * The grid this track belongs to, which is also what a binding inside it
    * resolves against.
    *
    * The whole of why a definition is a StyledElement rather than a struct:
    * value inheritance and, later, resource lookup and DataContext all walk
    * this link.
    */
    override @property inout(StyledElement) logicalParent() inout
    {
        return _owner;
    }

private:
   /*
    * What the sizing pass worked out, and which grid this track belongs to.
    *
    * Private rather than package: the only thing entitled to say either is the
    * Grid in this module, and module-scoped private is exactly that permission.
    */
    void setActualLength(float value)
    {
        setValue(actualLengthKey, Value(value));
    }

    /// ditto
    void setOwner(StyledElement value)
    {
        _owner = value;
    }

    static immutable(ReadOnlyPropertyKey) actualLengthKey;

    StyledElement _owner;
}

/// One row of a grid, read as a height.
class RowDefinition : DefinitionBase
{
    this()
    {
    }

    /// ditto
    this(GridLength height)
    {
        this.length = height;
    }

    /// The same properties DefinitionBase carries, read the way a row is read.
    @property GridLength height() const { return length; }
    /// ditto
    @property void height(GridLength value) { length = value; }
    /// ditto
    @property float minHeight() const { return minLength; }
    /// ditto
    @property void minHeight(float value) { minLength = value; }
    /// ditto
    @property float maxHeight() const { return maxLength; }
    /// ditto
    @property void maxHeight(float value) { maxLength = value; }
    /// ditto
    @property float actualHeight() const { return actualLength; }
}

/// One column of a grid, read as a width.
class ColumnDefinition : DefinitionBase
{
    this()
    {
    }

    /// ditto
    this(GridLength width)
    {
        this.length = width;
    }

    /// The same properties DefinitionBase carries, read the way a column is read.
    @property GridLength width() const { return length; }
    /// ditto
    @property void width(GridLength value) { length = value; }
    /// ditto
    @property float minWidth() const { return minLength; }
    /// ditto
    @property void minWidth(float value) { minLength = value; }
    /// ditto
    @property float maxWidth() const { return maxLength; }
    /// ditto
    @property void maxWidth(float value) { maxLength = value; }
    /// ditto
    @property float actualWidth() const { return actualLength; }
}

/*
 * A track's length is a length: not negative, not infinite, not NaN.
 *
 * Infinity is refused for the same reason StackPanel refuses an infinite gap --
 * it would reach the sum in measureOverride and trip the finite-answer assert
 * inside Element.measure, reporting a fault in a method the caller never wrote.
 * A star weight of zero is allowed and means "take nothing", which is a usable
 * thing to say; a negative one is not.
 */
private bool isUsableLength(const(Value) value)
{
    immutable length = value.get!GridLength;
    return length.value >= 0 && length.value < float.infinity;
}

/*
 * A bound is a length too, except that an infinite maximum is exactly how a
 * track says it has none -- which is why this one lets infinity through and
 * only NaN and negatives are refused.
 */
private bool isUsableBound(const(Value) value)
{
    immutable bound = value.get!float;
    return bound >= 0;
}

unittest
{
    // The three kinds, and what each of them carries.
    immutable fixed = GridLength(120);
    assert(fixed.isAbsolute && !fixed.isAuto && !fixed.isStar);
    assert(fixed.value == 120);
    assert(fixed.unitType == GridUnitType.pixel);

    immutable content = GridLength.autoSize;
    assert(content.isAuto);
    assert(content.value == 0, "an auto length carries no number, and says so as zero");

    immutable share = GridLength.star(2);
    assert(share.isStar && share.value == 2);
    assert(GridLength.star().value == 1, "one share unless another is asked for");

    // The struct's own default and a definition's default are different things,
    // deliberately.
    assert(GridLength.init == GridLength(0));
    assert(GridLength.init.isAbsolute);
}

unittest
{
    // A definition nobody has described takes a share of the room and is held
    // between nothing.
    auto column = new ColumnDefinition;

    assert(column.width.isStar && column.width.value == 1);
    assert(column.minWidth == 0);
    assert(column.maxWidth == float.infinity);
    assert(column.actualWidth == 0, "nothing has been laid out yet");

    // The axis aliases are the same properties read differently.
    column.width = GridLength(80);
    assert(column.length == GridLength(80));

    column.length = GridLength.autoSize;
    assert(column.width.isAuto);
}

unittest
{
    // A row reads as a height and a column as a width, and both are the one set
    // of properties underneath -- which is what lets the sizing code be written
    // once for both axes.
    auto row = new RowDefinition(GridLength(30));

    assert(row.height == GridLength(30));
    assert(row.getValue(DefinitionBase.lengthProperty).get!GridLength == GridLength(30));

    row.minHeight = 10;
    row.maxHeight = 90;
    assert(row.minLength == 10 && row.maxLength == 90);
}

unittest
{
    import std.exception : assertThrown;

    // What a track's length may not be.  Each of these would otherwise reach
    // the sum in the sizing pass and trip an assertion somewhere the caller
    // never wrote.
    auto column = new ColumnDefinition;

    assertThrown(column.setValue(DefinitionBase.lengthProperty, Value(GridLength(-5))));
    assertThrown(column.setValue(DefinitionBase.lengthProperty, Value(GridLength(float.infinity))));
    assertThrown(column.setValue(DefinitionBase.lengthProperty, Value(GridLength(float.nan))));
    assertThrown(column.setValue(DefinitionBase.lengthProperty, Value(GridLength.star(-1))));

    assert(column.width.isStar && column.width.value == 1, "and none of them disturbed it");

    // A star of no weight takes nothing, which is a usable thing to ask for.
    column.width = GridLength.star(0);
    assert(column.width.value == 0);

    // An infinite maximum is how a track says it has none; a negative bound is
    // not a bound.
    column.maxWidth = float.infinity;
    assertThrown(column.setValue(DefinitionBase.minLengthProperty, Value(-1.0f)));
    assertThrown(column.setValue(DefinitionBase.maxLengthProperty, Value(float.nan)));
}

unittest
{
    // What a definition actually is: a styled element and nothing more.  It has
    // no place in the visual tree, no size of its own and is never hit.
    auto row = new RowDefinition;

    assert(cast(StyledElement) row !is null);
    assert(row.logicalParent is null, "until a grid takes it");

    // The actual length is the grid's answer and only the grid may write it.
    assert(DefinitionBase.actualLengthProperty.isReadOnly);
}
