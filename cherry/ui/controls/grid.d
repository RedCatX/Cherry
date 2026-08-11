module cherry.ui.controls.grid;

/*
 * A module constructor here is safe for the reason stackpanel.d's banner spells
 * out: the imports of this package run one way.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : Rect, Size;
import cherry.ui.element;
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

        lengthProperty = Property.register("length",
            getRtti!GridLength(), getRtti!DefinitionBase(), lengthMeta, &isUsableLength);

        // Zero and infinity, which are the two lengths that change nothing --
        // the same pair, and the same reasoning, as Element's MinWidth/MaxWidth.
        PropertyMetadata minMeta;
        minMeta.defaultValue = Value(0.0f);

        minLengthProperty = Property.register("minLength",
            getRtti!float(), getRtti!DefinitionBase(), minMeta, &isUsableBound);

        PropertyMetadata maxMeta;
        maxMeta.defaultValue = Value(float.infinity);

        maxLengthProperty = Property.register("maxLength",
            getRtti!float(), getRtti!DefinitionBase(), maxMeta, &isUsableBound);

        // Written by the grid's sizing pass and by nothing else, so it takes a
        // key -- and the key never leaves this module.
        PropertyMetadata actualMeta;
        actualMeta.defaultValue = Value(0.0f);

        actualLengthKey = Property.registerReadOnly("actualLength",
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

/**
 * Lays its children out in rows and columns, dividing the room between them.
 *
 * The first container that *divides* rather than merely placing one thing after
 * another, which is what makes a form possible: two columns of cells line up
 * across every row, because it is the columns and not the cells that decide the
 * width.
 *
 * **Where a child goes is a property of the child**, attached to it by this
 * class: `Grid.setRow(button, 1)`.  It has to be, because there is nothing else
 * for it to be -- a Button knows nothing about grids, and a grid that kept its
 * own table of who sits where would have to be told every time a child moved.
 *
 * A grid with no definitions at all is one row and one column of a single star,
 * which makes it an ordinary single-cell container -- the same thing a plain
 * Element is, so nothing is lost by reaching for a Grid early.
 *
 * Not a Panel, because there is still no Panel: what WPF puts there is Children
 * (Element has it), Background (Control has it) and IsItemsHost (there are no
 * templates), so the base class would be empty.
 */
class Grid : Element
{
    shared static this()
    {
        // Which cell a child sits in changes how much room the grid needs, so
        // it is the parent's measure that has to be redone -- the child itself
        // is unaffected until the grid hands it a different slot.
        PropertyMetadata cellMeta;
        cellMeta.defaultValue = Value(0);
        cellMeta.affectsParentMeasure = true;

        rowProperty = Property.registerAttached("row",
            getRtti!int(), getRtti!Grid(), cellMeta, &isUsableIndex);
        columnProperty = Property.registerAttached("column",
            getRtti!int(), getRtti!Grid(), cellMeta, &isUsableIndex);

        PropertyMetadata spanMeta;
        spanMeta.defaultValue = Value(1);
        spanMeta.affectsParentMeasure = true;

        rowSpanProperty = Property.registerAttached("rowSpan",
            getRtti!int(), getRtti!Grid(), spanMeta, &isUsableSpan);
        columnSpanProperty = Property.registerAttached("columnSpan",
            getRtti!int(), getRtti!Grid(), spanMeta, &isUsableSpan);

        // **The four lines that make the flags above work at all.**
        //
        // Property.register keeps only the default *value* in a property's bare
        // metadata and attaches everything else as an override on the owner
        // type; an object resolves metadata by walking its own class chain.  A
        // Button given a Grid.Row therefore never reaches Grid, gets the bare
        // metadata, and affectsParentMeasure is not there -- so the grid would
        // never be told, and nothing would look wrong except the layout.
        //
        // Overriding for Element puts the flags where every child will find
        // them.  An attached property may be overridden for any host type,
        // which is exactly what that permission is for.
        rowProperty.overrideMetadata(getRtti!Element(), cellMeta);
        columnProperty.overrideMetadata(getRtti!Element(), cellMeta);
        rowSpanProperty.overrideMetadata(getRtti!Element(), spanMeta);
        columnSpanProperty.overrideMetadata(getRtti!Element(), spanMeta);

        // Room between the cells is room the grid has to ask its parent for, so
        // it is a measure and not merely an arrange -- the same reasoning, and
        // the same validator, as StackPanel's Spacing.
        PropertyMetadata gapMeta;
        gapMeta.defaultValue = Value(0.0f);
        gapMeta.affectsMeasure = true;

        rowSpacingProperty = Property.register("rowSpacing",
            getRtti!float(), getRtti!Grid(), gapMeta, &isFiniteSpacing);
        columnSpacingProperty = Property.register("columnSpacing",
            getRtti!float(), getRtti!Grid(), gapMeta, &isFiniteSpacing);
    }

    static immutable(Property) rowProperty;
    static immutable(Property) columnProperty;
    static immutable(Property) rowSpanProperty;
    static immutable(Property) columnSpanProperty;
    static immutable(Property) rowSpacingProperty;
    static immutable(Property) columnSpacingProperty;

   /**
    * Room left between neighbouring tracks, and only between them: n tracks get
    * n - 1 gaps, none before the first and none after the last.
    *
    * WPF has no such thing and makes every cell carry a margin instead, which
    * puts the same number in a dozen places and gets it wrong in one of them.
    * Avalonia, WinUI and CSS Grid all grew one; StackPanel here already has it.
    *
    * It adds to whatever margins the children carry rather than replacing them,
    * and a negative gap pulls the tracks together and past each other -- both
    * exactly as StackPanel's does.
    */
    @property float rowSpacing() const
    {
        return getValue(rowSpacingProperty).get!float;
    }

    /// ditto
    @property void rowSpacing(float value)
    {
        setValue(rowSpacingProperty, Value(value));
    }

    /// ditto
    @property float columnSpacing() const
    {
        return getValue(columnSpacingProperty).get!float;
    }

    /// ditto
    @property void columnSpacing(float value)
    {
        setValue(columnSpacingProperty, Value(value));
    }

   /**
    * Which cell a child sits in, and how many tracks it covers.
    *
    * Static, taking the child, because that is what an attached property is:
    * the value lives on the child and the meaning belongs to the grid.  An
    * index past the last track is pinned to the last one rather than refused --
    * a child put in row 5 of a three-row grid is a mistake worth seeing on the
    * screen, not one worth ending the program over.
    */
    static int getRow(const(Element) element)
    {
        return element.getValue(rowProperty).get!int;
    }

    /// ditto
    static void setRow(Element element, int value)
    {
        element.setValue(rowProperty, Value(value));
    }

    /// ditto
    static int getColumn(const(Element) element)
    {
        return element.getValue(columnProperty).get!int;
    }

    /// ditto
    static void setColumn(Element element, int value)
    {
        element.setValue(columnProperty, Value(value));
    }

    /// ditto
    static int getRowSpan(const(Element) element)
    {
        return element.getValue(rowSpanProperty).get!int;
    }

    /// ditto
    static void setRowSpan(Element element, int value)
    {
        element.setValue(rowSpanProperty, Value(value));
    }

    /// ditto
    static int getColumnSpan(const(Element) element)
    {
        return element.getValue(columnSpanProperty).get!int;
    }

    /// ditto
    static void setColumnSpan(Element element, int value)
    {
        element.setValue(columnSpanProperty, Value(value));
    }

   /**
    * Adds a row, and the same for a column.
    *
    * Shaped like addChild rather than as a collection object: the framework has
    * one way of adding things to an element and this is it.  The overload
    * taking a length is the one almost every caller wants, and it hands back
    * the definition it made so that a bound can be put on it.
    */
    void addRow(RowDefinition definition)
    in {
        assert(definition !is null);
    }
    do {
        _rows ~= definition;
        definition.setOwner(this);
        invalidateMeasure();
    }

    /// ditto
    RowDefinition addRow(GridLength height)
    {
        auto definition = new RowDefinition(height);
        addRow(definition);
        return definition;
    }

    /// ditto
    void addColumn(ColumnDefinition definition)
    in {
        assert(definition !is null);
    }
    do {
        _columns ~= definition;
        definition.setOwner(this);
        invalidateMeasure();
    }

    /// ditto
    ColumnDefinition addColumn(GridLength width)
    {
        auto definition = new ColumnDefinition(width);
        addColumn(definition);
        return definition;
    }

    /// How many rows and columns were defined.  Zero means the implicit cell.
    @property size_t rowCount() const pure nothrow @nogc
    {
        return _rows.length;
    }

    /// ditto
    @property size_t columnCount() const pure nothrow @nogc
    {
        return _columns.length;
    }

   /**
    * The definition at an index.
    *
    * The cast is safe by construction: nothing but addRow puts anything into
    * the array, and it takes a RowDefinition.  The array is declared as the
    * base so that the sizing code can be written once for both axes -- D has no
    * covariance for mutable arrays, and building a view per pass would allocate
    * on every layout.
    */
    RowDefinition row(size_t index)
    in {
        assert(index < _rows.length);
    }
    do {
        return cast(RowDefinition) _rows[index];
    }

    /// ditto
    ColumnDefinition column(size_t index)
    in {
        assert(index < _columns.length);
    }
    do {
        return cast(ColumnDefinition) _columns[index];
    }

    /// Removes every row, or every column.  The children stay where they are.
    void clearRows()
    {
        foreach (definition; _rows)
            definition.setOwner(null);

        _rows = null;
        invalidateMeasure();
    }

    /// ditto
    void clearColumns()
    {
        foreach (definition; _columns)
            definition.setOwner(null);

        _columns = null;
        invalidateMeasure();
    }

protected:
   /**
    * Works out how long every track is, then asks for the sum of them.
    *
    * The order is forced by the kinds of length and by nothing else.  A pixel
    * track is known at once.  An auto track is known once the children in it
    * have been measured.  A star track is known only after both, because it
    * divides what those two leave behind -- so the passes are: fix the pixels,
    * grow the autos, divide the remainder, and then measure everybody against
    * the tracks they will really be given.
    *
    * **Both axes are resolved together and not one after the other**, because a
    * child answers with a width and a height at the same time: a single measure
    * of it feeds an auto column and an auto row at once.
    *
    * A star with nothing to divide is an auto.  An unbounded offer is the
    * question "how big would you like to be?", and a share of an unbounded
    * remainder is not an answer to it -- so under infinity a star sizes itself
    * to its content, which is also what keeps this method's answer finite.
    */
    override Size measureOverride(Size availableSize)
    {
        auto columns = columnAxis();
        auto rows = rowAxis();

        resolveFixedTracks(columns, availableSize.width);
        resolveFixedTracks(rows, availableSize.height);

        growAutoTracks(columns, rows, availableSize);

        divideRemainder(columns, availableSize.width);
        divideRemainder(rows, availableSize.height);

        measureChildren(columns, rows);

        // Floored, because a gap negative enough to out-pull the tracks is a
        // direction rather than a length, and a size is not negative.  Only the
        // answer is floored: the offsets below let the cursor run backwards,
        // since overlapping is what was asked for.
        return Size(atLeastZero(columns.total), atLeastZero(rows.total));
    }

   /**
    * Places every child in the cell it was given.
    *
    * The stars are divided again here, against the room actually granted rather
    * than the room asked for: a grid stretched by its parent has to hand the
    * extra to the tracks that were meant to take it.  The auto tracks are left
    * as they were measured -- they are about their content, and the content did
    * not change because the window got wider.
    */
    override Size arrangeOverride(Size finalSize)
    {
        auto columns = columnAxis();
        auto rows = rowAxis();

        divideRemainder(columns, finalSize.width);
        divideRemainder(rows, finalSize.height);

        publishActualLengths();

        auto view = children;

        foreach (i; 0 .. view.length)
        {
            auto child = view[i];

            immutable ci = trackIndex(getColumn(child), columns.count);
            immutable ri = trackIndex(getRow(child), rows.count);
            immutable cs = trackSpan(getColumnSpan(child), ci, columns.count);
            immutable rs = trackSpan(getRowSpan(child), ri, rows.count);

            child.arrange(Rect(columns.offsetOf(ci), rows.offsetOf(ri),
                               columns.extentOf(ci, cs), rows.extentOf(ri, rs)));
        }

        return finalSize;
    }

private:
   /*
    * One axis of the grid, as the sizing code sees it: the definitions, the
    * resolved sizes beside them, and nothing about which way it points.
    *
    * A view over the grid's own arrays rather than a copy -- writing to `sizes`
    * writes to the grid.  Built fresh on each pass because it is three words;
    * the arrays it points at are kept.
    */
    static struct Axis
    {
        DefinitionBase[] definitions;
        float[]          sizes;
       /*
        * Which tracks the division below has finished with -- either because
        * they never took a share, or because they ran into a bound and were
        * fixed at it.  Kept beside the sizes rather than worked out again on
        * every pass, which is what lets the division be a plain loop.
        */
        bool[]           settled;
        /// Room between neighbouring tracks; see Grid.rowSpacing.
        float            spacing = 0;

       /*
        * How many tracks there really are.  A grid with no definitions has one
        * implicit track, so this is never zero and every division below is safe.
        */
        @property size_t count() const pure nothrow @nogc
        {
            return definitions.length ? definitions.length : 1;
        }

        GridLength lengthAt(size_t index) const
        {
            return definitions.length ? definitions[index].length : GridLength.star(1);
        }

        float minAt(size_t index) const
        {
            return definitions.length ? definitions[index].minLength : 0;
        }

        float maxAt(size_t index) const
        {
            return definitions.length ? definitions[index].maxLength : float.infinity;
        }

       /*
        * Whether this track's size comes from what is in it.  True for an auto
        * track always, and for a star track when there is no remainder to
        * divide because nothing bounded it.
        */
        bool growsFromContent(size_t index, float available) const
        {
            immutable length = lengthAt(index);
            return length.isAuto || (length.isStar && !(available < float.infinity));
        }

        /// Whether this track takes a share of what the others leave.
        bool sharesRemainder(size_t index, float available) const
        {
            return lengthAt(index).isStar && available < float.infinity;
        }

       /*
        * Whether a child covering these tracks can decide how big they are.
        *
        * Yes when at least one of them grows from its content and **none** of
        * them takes a share of the remainder.  That second condition is the
        * limit worth knowing: a child spanning an auto track and a star track
        * grows neither of them.  Its size cannot say how the auto should grow,
        * because the star beside it may be about to take the whole span --
        * and the alternative, letting the content decide the auto first, makes
        * a wide child push a column out to its full width and then leaves the
        * star with nothing to do.  WPF resolves this with an extra pass over
        * the children in exactly this position; here it is one rule instead.
        */
        bool spanGrowsFromContent(size_t index, size_t span, float available) const
        {
            bool anyContent = false;

            foreach (i; index .. index + span)
            {
                if (sharesRemainder(i, available))
                    return false;

                if (growsFromContent(i, available))
                    anyContent = true;
            }

            return anyContent;
        }

       /*
        * Every gap on the axis added up.
        *
        * Written with the guard rather than as `(count - 1) * spacing`, because
        * count is a size_t and a single track would otherwise buy four billion
        * gaps -- the same trap, spelled the same way, as in StackPanel.
        */
        @property float spacingTotal() const pure nothrow @nogc
        {
            return count > 1 ? spacing * (count - 1) : 0;
        }

        /// The whole length of the axis: every track and every gap.
        @property float total() const pure nothrow @nogc
        {
            float sum = spacingTotal;
            foreach (size; sizes[0 .. count])
                sum += size;

            return sum;
        }

        /// Where a track starts: everything before it, and the gaps to it.
        float offsetOf(size_t index) const pure nothrow @nogc
        {
            float offset = spacing * index;
            foreach (i; 0 .. index)
                offset += sizes[i];

            return offset;
        }

       /*
        * How long a run of tracks is, gaps included.
        *
        * The gaps *inside* the run and not the ones around it: a child covering
        * two columns covers the space between them as well, because there is
        * nothing else that could be in it.
        */
        float extentOf(size_t index, size_t span) const pure nothrow @nogc
        {
            float sum = span > 1 ? spacing * (span - 1) : 0;

            foreach (i; index .. index + span)
                sum += sizes[i];

            return sum;
        }

       /*
        * Gives a child's unmet size to the tracks under it that grow from
        * their content, sharing it equally between them.
        *
        * Equally, and not in proportion to what they already are: there is no
        * reason to think a track that happens to be wider deserves more of a
        * child that spans both.  For a child in a single track this reduces to
        * "the track is at least as big as the child", which is the whole of the
        * unspanned case and is why there is only one rule here.
        */
        void giveToContent(size_t index, size_t span, float wanted, float available)
        {
            // The gaps inside the span are already part of what the child has.
            float have = span > 1 ? spacing * (span - 1) : 0;
            size_t growing = 0;

            foreach (i; index .. index + span)
            {
                have += sizes[i];

                if (growsFromContent(i, available))
                    ++growing;
            }

            if (growing == 0)
                return;

            immutable shortfall = wanted - have;
            if (!(shortfall > 0))
                return;

            immutable share = shortfall / growing;

            foreach (i; index .. index + span)
            {
                if (growsFromContent(i, available))
                    sizes[i] = clampLength(sizes[i] + share, minAt(i), maxAt(i));
            }
        }
    }

    Axis columnAxis()
    {
        ensureTracks(_columnSizes, _columnSettled, _columns.length);
        return Axis(_columns, _columnSizes, _columnSettled, columnSpacing);
    }

    Axis rowAxis()
    {
        ensureTracks(_rowSizes, _rowSettled, _rows.length);
        return Axis(_rows, _rowSizes, _rowSettled, rowSpacing);
    }

   /*
    * Keeps the working arrays as long as the definitions, with room for the
    * implicit track when there are none.  Reused between passes rather than
    * allocated per pass: layout runs on every frame that changes anything.
    */
    static void ensureTracks(ref float[] sizes, ref bool[] settled, size_t definitions)
    {
        immutable wanted = definitions ? definitions : 1;

        if (sizes.length != wanted)
            sizes.length = wanted;

        if (settled.length != wanted)
            settled.length = wanted;
    }

   /*
    * The tracks whose length was known before anything was measured, plus the
    * floor every other track starts from.
    */
    static void resolveFixedTracks(ref Axis axis, float available)
    {
        foreach (i; 0 .. axis.count)
        {
            immutable length = axis.lengthAt(i);

            axis.sizes[i] = length.isAbsolute
                ? clampLength(length.value, axis.minAt(i), axis.maxAt(i))
                : axis.minAt(i);
        }
    }

   /*
    * Grows the content-sized tracks to fit what is in them.
    *
    * Only the children that land in such a track are measured here, and they
    * are offered infinity on every axis that is not already fixed -- the
    * question being asked is how big they would like to be, and a track that
    * grows to its content has to hear the real answer.
    *
    * A child in a track that will take a share of the remainder is left alone:
    * its size cannot be known yet, and it is measured for real in the last pass.
    */
    void growAutoTracks(ref Axis columns, ref Axis rows, Size availableSize)
    {
        auto view = children;

        foreach (i; 0 .. view.length)
        {
            auto child = view[i];

            immutable ci = trackIndex(getColumn(child), columns.count);
            immutable ri = trackIndex(getRow(child), rows.count);
            immutable cs = trackSpan(getColumnSpan(child), ci, columns.count);
            immutable rs = trackSpan(getRowSpan(child), ri, rows.count);

            immutable growsWide = columns.spanGrowsFromContent(ci, cs, availableSize.width);
            immutable growsTall = rows.spanGrowsFromContent(ri, rs, availableSize.height);

            if (!growsWide && !growsTall)
                continue;

            // Infinity on the axis the child gets to decide, and the tracks as
            // they stand on the other -- which may be provisional, since a star
            // beside it has not been divided yet.  What that costs is a child
            // whose height depends on its width, wrapped text above all: it is
            // measured here against a width it may not end up with.  The last
            // pass measures it again against the real one.
            child.measure(Size(growsWide ? float.infinity : columns.extentOf(ci, cs),
                               growsTall ? float.infinity : rows.extentOf(ri, rs)));

            immutable wanted = child.desiredSize;

            if (growsWide)
                columns.giveToContent(ci, cs, wanted.width, availableSize.width);

            if (growsTall)
                rows.giveToContent(ri, rs, wanted.height, availableSize.height);
        }
    }

   /*
    * Divides what the fixed and content-sized tracks left over among the stars,
    * in proportion to their weights and inside their bounds.
    *
    * The bounds are what make this a loop rather than one division.  A track
    * whose share falls outside them cannot take that share; it is fixed at the
    * bound it hit, leaves the division, and what it did not take is divided
    * again among the tracks still free -- which may push another one into a
    * bound, and so on.  Each pass either settles everything or removes at least
    * one track, so it cannot run more times than there are tracks.
    *
    * Nothing to do when the offer is unbounded: those tracks were sized by
    * their content in the pass above, and there is no remainder of infinity.
    */
    static void divideRemainder(ref Axis axis, float available)
    {
        if (!(available < float.infinity))
            return;

        // The gaps come out of the room before anything is divided: they are
        // there whatever the tracks turn out to be.
        float taken = axis.spacingTotal;

        foreach (i; 0 .. axis.count)
        {
            axis.settled[i] = !axis.sharesRemainder(i, available);

            if (axis.settled[i])
                taken += axis.sizes[i];
            else
                axis.sizes[i] = axis.minAt(i);   // a floor to fall back to
        }

        float remaining = available - taken;
        if (!(remaining > 0))
            remaining = 0;

        for (;;)
        {
            float weight = 0;

            foreach (i; 0 .. axis.count)
            {
                if (!axis.settled[i])
                    weight += axis.lengthAt(i).value;
            }

            // Nothing left that wants a share: what is unsettled asked for a
            // weight of zero, which is a way of saying it wants nothing, and it
            // keeps the minimum it was given above.
            if (!(weight > 0))
                return;

            bool hitABound = false;

            foreach (i; 0 .. axis.count)
            {
                if (axis.settled[i])
                    continue;

                immutable share = remaining * axis.lengthAt(i).value / weight;
                immutable held = clampLength(share, axis.minAt(i), axis.maxAt(i));

                axis.sizes[i] = held;

                if (held != share)
                {
                    axis.settled[i] = true;
                    remaining -= held;

                    if (!(remaining > 0))
                        remaining = 0;

                    hitABound = true;
                }
            }

            // The shares the pass just handed out are only final if nobody was
            // pushed into a bound; otherwise there is less to go round and the
            // ones still free are divided again.
            if (!hitABound)
                return;
        }
    }

   /*
    * The measure that counts: every child against the track it will really be
    * given.
    *
    * A child already measured while its auto track was being grown is measured
    * again here, because the offer is different -- infinity then, the settled
    * size now.  Element.measure only repeats the work when the constraint has
    * actually changed, so a child in a pixel cell is measured exactly once.
    */
    void measureChildren(ref Axis columns, ref Axis rows)
    {
        auto view = children;

        foreach (i; 0 .. view.length)
        {
            auto child = view[i];

            immutable ci = trackIndex(getColumn(child), columns.count);
            immutable ri = trackIndex(getRow(child), rows.count);
            immutable cs = trackSpan(getColumnSpan(child), ci, columns.count);
            immutable rs = trackSpan(getRowSpan(child), ri, rows.count);

            child.measure(Size(columns.extentOf(ci, cs), rows.extentOf(ri, rs)));
        }
    }

   /*
    * Tells every definition how long it turned out to be.
    *
    * Written during arrange, which is safe because a definition is a
    * StyledElement and not an Element: nothing about it invalidates a layout,
    * so this cannot start the pass it is running inside over again.
    */
    void publishActualLengths()
    {
        foreach (i, definition; _columns)
            definition.setActualLength(_columnSizes[i]);

        foreach (i, definition; _rows)
            definition.setActualLength(_rowSizes[i]);
    }

   /*
    * The track a child asked for, pinned to one that exists.
    *
    * A count is never zero -- there is always the implicit track -- so this
    * always names a real track.
    */
    static size_t trackIndex(int value, size_t count) pure nothrow @nogc
    {
        if (value <= 0)
            return 0;

        return cast(size_t) value >= count ? count - 1 : cast(size_t) value;
    }

   /*
    * How many tracks a child really covers: what it asked for, cut down to what
    * is left after the one it starts in.
    *
    * A span of zero or less is one track, which is the same pinning trackIndex
    * does and for the same reason -- a span that covered nothing would be a
    * child with nowhere to be.
    */
    static size_t trackSpan(int value, size_t index, size_t count) pure nothrow @nogc
    {
        if (value <= 1)
            return 1;

        immutable room = count - index;
        return cast(size_t) value > room ? room : cast(size_t) value;
    }

    DefinitionBase[] _rows;
    DefinitionBase[] _columns;
    float[]          _rowSizes;
    float[]          _columnSizes;
    bool[]           _rowSettled;
    bool[]           _columnSettled;
}

/*
 * A length held between its bounds, with the maximum applied before the
 * minimum -- the order Element.measure uses, and for the same reason: a minimum
 * larger than the maximum is a contradiction, and the one the author wrote last
 * is the one they meant.
 */
private float clampLength(float value, float min, float max) pure nothrow @nogc
{
    if (value > max)
        value = max;
    if (value < min)
        value = min;

    return value > 0 ? value : 0;
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
 * A gap is a length, and neither infinity nor NaN is one.  Negatives overlap
 * the tracks, which is what a negative margin already does.  Written as two
 * comparisons rather than through std.math.isFinite because NaN fails both,
 * which is the whole point -- the same line StackPanel carries.
 */
private bool isFiniteSpacing(const(Value) value)
{
    immutable gap = value.get!float;
    return gap > -float.infinity && gap < float.infinity;
}

/// A cell index names a track, so it is not negative.
private bool isUsableIndex(const(Value) value)
{
    return value.get!int >= 0;
}

/// A span covers at least the track it starts in.
private bool isUsableSpan(const(Value) value)
{
    return value.get!int >= 1;
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

version (unittest)
{
    import cherry.platform.render : Thickness;

   /*
    * A child with a size of its own in both directions, pinned to the top left
    * of whatever slot it is given.
    *
    * The pinning is not decoration.  An element that insists on both its width
    * and its height cannot be stretched, so the default alignment centres it in
    * its slot -- and a placement test written with an unpinned fixture reads the
    * centring, calls it the grid, and passes for the wrong reason.  This has now
    * caught four different tests in this framework; pinning it here is what
    * stops it catching a fifth.
    */
    private static class Box : Element
    {
        this(float w, float h)
        {
            width = w;
            height = h;
            horizontalAlignment = HorizontalAlignment.left;
            verticalAlignment = VerticalAlignment.top;
        }
    }

   /*
    * A child with no size of its own, which is what most things in a grid are:
    * it takes the cell it is given.  Records what it was offered, which is the
    * half of a measure a test cannot read off the element afterwards.
    */
    private static class Filler : Element
    {
        Size seenAvailable;

        protected override Size measureOverride(Size availableSize)
        {
            seenAvailable = availableSize;
            return Size(0, 0);
        }
    }

    /// Measures and arranges in one go, so no test can forget the first half.
    private void layOut(Element root, Size room)
    {
        root.measure(room);
        root.arrange(Rect(0, 0, room.width, room.height));
    }

    /// A child in a cell, added and placed in one line.
    private Element cell(Grid grid, Element child, int column, int row)
    {
        Grid.setColumn(child, column);
        Grid.setRow(child, row);
        grid.addChild(child);
        return child;
    }
}

unittest
{
    // The trap this whole design turns on: an attached property carries its
    // flags to the child that was given it.
    //
    // Property.register puts the flags on the owner type, and a child resolves
    // metadata through its own class chain, which never reaches Grid -- so
    // without the override in the module constructor this fails, silently and
    // only in the layout.
    auto grid = new Grid;
    auto child = new Box(40, 20);
    grid.addChild(child);

    grid.measure(Size(200, 100));
    grid.arrange(Rect(0, 0, 200, 100));
    assert(grid.isMeasureValid);

    Grid.setRow(child, 1);
    assert(!grid.isMeasureValid, "moving a child to another cell changes what the grid needs");

    grid.measure(Size(200, 100));
    assert(grid.isMeasureValid);

    Grid.setColumnSpan(child, 2);
    assert(!grid.isMeasureValid, "and so does covering more of it");
}

unittest
{
    import std.exception : assertThrown;

    // A cell index names a track and a span covers at least one.
    auto child = new Element;

    assert(Grid.getRow(child) == 0 && Grid.getColumn(child) == 0);
    assert(Grid.getRowSpan(child) == 1 && Grid.getColumnSpan(child) == 1);

    Grid.setRow(child, 3);
    assert(Grid.getRow(child) == 3);

    assertThrown(Grid.setRow(child, -1));
    assertThrown(Grid.setColumnSpan(child, 0));
    assert(Grid.getRow(child) == 3, "and the refusals left it alone");
}

unittest
{
    // Pixel tracks are what they say, and the grid is their sum.
    auto grid = new Grid;
    grid.addColumn(GridLength(60));
    grid.addColumn(GridLength(40));
    grid.addRow(GridLength(30));

    cell(grid, new Filler, 0, 0);
    cell(grid, new Filler, 1, 0);

    layOut(grid, Size(500, 400));

    assert(grid.desiredSize == Size(100, 30));
    assert(grid.column(0).actualWidth == 60 && grid.column(1).actualWidth == 40);
    assert(grid.row(0).actualHeight == 30);
}

unittest
{
    // An auto track is as big as the biggest thing in it, and no bigger.
    auto grid = new Grid;
    grid.addColumn(GridLength.autoSize);
    grid.addColumn(GridLength.autoSize);
    grid.addRow(GridLength.autoSize);

    auto narrow = cell(grid, new Box(30, 10), 0, 0);
    auto wide = cell(grid, new Box(70, 25), 1, 0);

    layOut(grid, Size(500, 400));

    assert(grid.column(0).actualWidth == 30);
    assert(grid.column(1).actualWidth == 70);
    assert(grid.row(0).actualHeight == 25, "the taller of the two");
    assert(grid.desiredSize == Size(100, 25));

    // Each at its own size, in the cell it was given: the row is 25 tall
    // because of the other one, and the short child does not grow to fill it --
    // it is pinned to the top and has a height of its own.
    assert(narrow.arrangedRect == Rect(0, 0, 30, 10));
    assert(wide.arrangedRect == Rect(30, 0, 70, 25));
}

unittest
{
    // Stars divide what the others leave, by weight.
    auto grid = new Grid;
    grid.addColumn(GridLength(100));
    grid.addColumn(GridLength.star(1));
    grid.addColumn(GridLength.star(2));

    foreach (i; 0 .. 3)
        cell(grid, new Filler, cast(int) i, 0);

    layOut(grid, Size(400, 50));

    assert(grid.column(0).actualWidth == 100);
    assert(grid.column(1).actualWidth == 100, "one part of the three hundred left");
    assert(grid.column(2).actualWidth == 200, "and two");
}

unittest
{
    // A star with nothing to divide is an auto -- which is also what keeps the
    // answer to an unbounded question finite.
    auto grid = new Grid;
    grid.addColumn(GridLength.star(1));
    grid.addColumn(GridLength.star(1));

    cell(grid, new Box(40, 10), 0, 0);
    cell(grid, new Box(70, 10), 1, 0);

    grid.measure(Size(float.infinity, float.infinity));

    assert(grid.desiredSize == Size(110, 10), "each star took its content, and the sum is a number");
}

unittest
{
    // The room a grid is given is not always the room it asked for, and the
    // difference belongs to the stars.
    auto grid = new Grid;
    grid.addColumn(GridLength(50));
    grid.addColumn(GridLength.star(1));

    auto fixed = cell(grid, new Filler, 0, 0);
    auto stretchy = cell(grid, new Filler, 1, 0);

    grid.measure(Size(200, 100));
    assert(grid.column(1).length.isStar);

    // Arranged into more room than the measure was given.
    grid.arrange(Rect(0, 0, 400, 100));

    assert(fixed.arrangedRect.width == 50, "the fixed track did not move");
    assert(stretchy.arrangedRect == Rect(50, 0, 350, 100), "and the star took all of the rest");
}

unittest
{
    // A grid nobody described is a single cell, and the child fills it -- the
    // same thing a plain Element does, so reaching for a Grid early costs
    // nothing.
    auto grid = new Grid;
    auto child = new Filler;
    grid.addChild(child);

    layOut(grid, Size(300, 200));

    assert(grid.rowCount == 0 && grid.columnCount == 0);
    assert(child.arrangedRect == Rect(0, 0, 300, 200));
    assert(child.seenAvailable == Size(300, 200));
}

unittest
{
    // A child put outside the grid is pinned to the last track rather than
    // ending the program: a mistake worth seeing on the screen.
    auto grid = new Grid;
    grid.addColumn(GridLength(40));
    grid.addColumn(GridLength(60));
    grid.addRow(GridLength(20));

    auto child = cell(grid, new Filler, 7, 3);

    layOut(grid, Size(500, 400));

    assert(child.arrangedRect == Rect(40, 0, 60, 20), "the last column and the only row");
}

unittest
{
    // Rows and columns are the same code pointed two ways, so the cheapest way
    // to say they are not confused is to transpose a case and check it again.
    auto grid = new Grid;
    grid.addRow(GridLength(100));
    grid.addRow(GridLength.star(1));
    grid.addRow(GridLength.star(2));

    foreach (i; 0 .. 3)
        cell(grid, new Filler, 0, cast(int) i);

    layOut(grid, Size(50, 400));

    assert(grid.row(0).actualHeight == 100);
    assert(grid.row(1).actualHeight == 100);
    assert(grid.row(2).actualHeight == 200);
}

unittest
{
    // The definitions belong to the grid, which is what a binding written
    // inside one will resolve against.
    auto grid = new Grid;
    auto column = grid.addColumn(GridLength(30));

    assert(column.logicalParent is grid);
    assert(grid.columnCount == 1 && grid.column(0) is column);

    grid.clearColumns();
    assert(grid.columnCount == 0);
    assert(column.logicalParent is null, "and it is let go when the grid drops it");
}

unittest
{
    // A star that would be given more than its maximum takes the maximum, and
    // what it left is divided again among the rest -- which is the whole reason
    // the division is a loop.
    auto grid = new Grid;
    auto capped = grid.addColumn(GridLength.star(1));
    grid.addColumn(GridLength.star(1));

    capped.maxWidth = 50;

    cell(grid, new Filler, 0, 0);
    cell(grid, new Filler, 1, 0);

    layOut(grid, Size(400, 50));

    assert(capped.actualWidth == 50, "it could not take its two hundred");
    assert(grid.column(1).actualWidth == 350, "and the other one took what was left over");
}

unittest
{
    // The same the other way: a minimum lifts a track above its share, and the
    // rest divide what remains.
    auto grid = new Grid;
    auto floored = grid.addColumn(GridLength.star(1));
    grid.addColumn(GridLength.star(3));

    floored.minWidth = 200;

    cell(grid, new Filler, 0, 0);
    cell(grid, new Filler, 1, 0);

    layOut(grid, Size(400, 50));

    assert(floored.actualWidth == 200, "a hundred was its share, and two hundred is its floor");
    assert(grid.column(1).actualWidth == 200);
}

unittest
{
    // Two bounds at once, so the division has to go round more than twice.
    auto grid = new Grid;
    auto first = grid.addColumn(GridLength.star(1));
    auto second = grid.addColumn(GridLength.star(1));
    grid.addColumn(GridLength.star(1));

    first.maxWidth = 20;
    second.maxWidth = 40;

    foreach (i; 0 .. 3)
        cell(grid, new Filler, cast(int) i, 0);

    layOut(grid, Size(300, 50));

    assert(first.actualWidth == 20);
    assert(second.actualWidth == 40);
    assert(grid.column(2).actualWidth == 240, "everything the other two could not take");
}

unittest
{
    // The bounds hold every kind of track, not only the stars.
    auto grid = new Grid;
    auto fixed = grid.addColumn(GridLength(500));
    auto content = grid.addColumn(GridLength.autoSize);

    fixed.maxWidth = 100;
    content.minWidth = 80;

    cell(grid, new Filler, 0, 0);
    cell(grid, new Box(30, 10), 1, 0);

    layOut(grid, Size(1000, 50));

    assert(fixed.actualWidth == 100, "a pixel track is held to its maximum too");
    assert(content.actualWidth == 80, "and an auto track cannot shrink below its minimum");
}

unittest
{
    // Minimums that between them want more than there is take what there is and
    // leave nothing, rather than going negative.
    auto grid = new Grid;
    auto first = grid.addColumn(GridLength.star(1));
    auto second = grid.addColumn(GridLength.star(1));

    first.minWidth = 300;
    second.minWidth = 300;

    cell(grid, new Filler, 0, 0);
    cell(grid, new Filler, 1, 0);

    layOut(grid, Size(400, 50));

    assert(first.actualWidth == 300);
    assert(second.actualWidth == 300, "both floors hold, and the grid overflows");
    assert(grid.desiredSize.width == 400, "which the grid reports only as far as it was offered");
    assert(grid.unclippedDesiredSize.width == 600, "the truth is still on the record");
}

unittest
{
    // A child covering two columns is placed across both of them.
    auto grid = new Grid;
    grid.addColumn(GridLength(40));
    grid.addColumn(GridLength(60));
    grid.addColumn(GridLength(30));
    grid.addRow(GridLength(20));

    auto wide = cell(grid, new Filler, 0, 0);
    Grid.setColumnSpan(wide, 2);

    auto last = cell(grid, new Filler, 2, 0);

    layOut(grid, Size(500, 400));

    assert(wide.arrangedRect == Rect(0, 0, 100, 20), "both columns, end to end");
    assert(last.arrangedRect == Rect(100, 0, 30, 20), "and the third is where it always was");
}

unittest
{
    // A span past the last track is cut down to what is there.
    auto grid = new Grid;
    grid.addColumn(GridLength(40));
    grid.addColumn(GridLength(60));
    grid.addRow(GridLength(20));

    auto greedy = cell(grid, new Filler, 1, 0);
    Grid.setColumnSpan(greedy, 9);

    layOut(grid, Size(500, 400));

    assert(greedy.arrangedRect == Rect(40, 0, 60, 20), "one column, because there is only one left");
}

unittest
{
    // A spanned child grows the auto columns under it, sharing what it needs
    // equally between them.
    auto grid = new Grid;
    grid.addColumn(GridLength.autoSize);
    grid.addColumn(GridLength.autoSize);
    grid.addRow(GridLength.autoSize);

    auto wide = cell(grid, new Box(100, 10), 0, 0);
    Grid.setColumnSpan(wide, 2);

    layOut(grid, Size(500, 400));

    assert(grid.column(0).actualWidth == 50);
    assert(grid.column(1).actualWidth == 50, "fifty each, because neither had a reason to be wider");
    assert(grid.desiredSize.width == 100);
}

unittest
{
    // The shortfall is what is missing and not the whole child: a column that
    // is already wide enough for its own content keeps that width, and only
    // what is left over is shared.
    auto grid = new Grid;
    grid.addColumn(GridLength.autoSize);
    grid.addColumn(GridLength.autoSize);
    grid.addRow(GridLength.autoSize);
    grid.addRow(GridLength.autoSize);

    // A tall child of its own in the first column, on its own row.
    cell(grid, new Box(80, 10), 0, 0);

    auto wide = cell(grid, new Box(100, 10), 0, 1);
    Grid.setColumnSpan(wide, 2);

    layOut(grid, Size(500, 400));

    assert(grid.column(0).actualWidth == 90, "eighty of its own, plus half of the twenty missing");
    assert(grid.column(1).actualWidth == 10);
    assert(grid.desiredSize.width == 100);
}

unittest
{
    // The recorded limit: a child spanning an auto track and a star track grows
    // neither of them.
    //
    // Not an oversight.  Its width cannot say how wide the auto should be,
    // because the star beside it is about to take whatever is left -- and
    // letting the content decide first would push the auto column out to the
    // child's full width and leave the star with nothing to do.  WPF spends an
    // extra pass over exactly these children; this is one rule instead, and the
    // case it costs is rare.
    auto grid = new Grid;
    grid.addColumn(GridLength.autoSize);
    grid.addColumn(GridLength.star(1));
    grid.addRow(GridLength(20));

    auto spanning = cell(grid, new Box(300, 10), 0, 0);
    Grid.setColumnSpan(spanning, 2);

    layOut(grid, Size(400, 400));

    assert(grid.column(0).actualWidth == 0, "nothing else asked for anything here");
    assert(grid.column(1).actualWidth == 400, "and the star took the lot");
    assert(spanning.arrangedRect.width == 300, "the child still gets the room it needs");
}

unittest
{
    // Spanning works down as well as across, and the two do not interfere.
    auto grid = new Grid;
    grid.addRow(GridLength(30));
    grid.addRow(GridLength(50));
    grid.addColumn(GridLength(40));

    auto tall = cell(grid, new Filler, 0, 0);
    Grid.setRowSpan(tall, 2);

    layOut(grid, Size(400, 400));

    assert(tall.arrangedRect == Rect(0, 0, 40, 80));
}

unittest
{
    import std.exception : assertThrown;

    // A gap takes any length and refuses what is not one.
    auto grid = new Grid;

    assert(grid.rowSpacing == 0 && grid.columnSpacing == 0, "cells touch until told otherwise");

    grid.columnSpacing = 8;
    assert(grid.columnSpacing == 8);

    grid.columnSpacing = -4;
    assert(grid.columnSpacing == -4, "a negative gap overlaps, as a negative margin does");

    assertThrown(grid.setValue(Grid.columnSpacingProperty, Value(float.infinity)));
    assertThrown(grid.setValue(Grid.columnSpacingProperty, Value(float.nan)));
    assert(grid.columnSpacing == -4, "and neither refusal disturbed what was there");
}

unittest
{
    // Gaps go between tracks and nowhere else: n tracks, n - 1 gaps, in the
    // size the grid asks for and in where it puts things.
    auto grid = new Grid;
    grid.columnSpacing = 10;
    grid.addColumn(GridLength(40));
    grid.addColumn(GridLength(60));
    grid.addColumn(GridLength(30));
    grid.addRow(GridLength(20));

    auto first = cell(grid, new Filler, 0, 0);
    auto second = cell(grid, new Filler, 1, 0);
    auto third = cell(grid, new Filler, 2, 0);

    layOut(grid, Size(500, 400));

    assert(grid.desiredSize.width == 150, "a hundred and thirty of track and two gaps");

    assert(first.arrangedRect.x == 0);
    assert(second.arrangedRect.x == 50, "forty of track and one gap");
    assert(third.arrangedRect.x == 120, "and a hundred of track and two gaps");

    assert(first.arrangedRect.width == 40, "a gap belongs to nobody");
}

unittest
{
    // One track has nothing to be between, and no track has less.
    auto one = new Grid;
    one.columnSpacing = 10;
    one.addColumn(GridLength(40));
    one.addRow(GridLength(20));
    cell(one, new Filler, 0, 0);

    one.measure(Size(500, 400));
    assert(one.desiredSize.width == 40, "one track buys no gaps, not four billion of them");

    // Nor does the implicit one.  Said as a difference rather than as a number,
    // because the number is the whole offer: the implicit track is a star, and
    // a star takes what it is given.
    auto bare = new Grid;
    bare.addChild(new Filler);

    bare.measure(Size(500, 400));
    immutable without = bare.desiredSize;

    bare.columnSpacing = 10;
    bare.rowSpacing = 10;
    bare.measure(Size(500, 400));

    assert(bare.desiredSize == without, "one track, no gaps, whatever the gap is set to");
    assert(without.width == 500, "and a star takes the room it was offered");
}

unittest
{
    // The gaps come out of the room before the stars divide what is left.
    auto grid = new Grid;
    grid.columnSpacing = 20;
    grid.addColumn(GridLength.star(1));
    grid.addColumn(GridLength.star(1));

    cell(grid, new Filler, 0, 0);
    cell(grid, new Filler, 1, 0);

    layOut(grid, Size(220, 50));

    assert(grid.column(0).actualWidth == 100);
    assert(grid.column(1).actualWidth == 100, "two hundred divided, and twenty left between them");
}

unittest
{
    // A child covering two tracks covers the gap between them too, because
    // there is nothing else that could be in it.
    auto grid = new Grid;
    grid.columnSpacing = 10;
    grid.addColumn(GridLength(40));
    grid.addColumn(GridLength(60));
    grid.addRow(GridLength(20));

    auto wide = cell(grid, new Filler, 0, 0);
    Grid.setColumnSpan(wide, 2);

    layOut(grid, Size(500, 400));

    assert(wide.arrangedRect == Rect(0, 0, 110, 20), "both tracks and the gap between them");
}

unittest
{
    // And an auto track under a spanned child is not asked to pay for the gap
    // the child already has.
    auto grid = new Grid;
    grid.columnSpacing = 10;
    grid.addColumn(GridLength.autoSize);
    grid.addColumn(GridLength.autoSize);
    grid.addRow(GridLength.autoSize);

    auto wide = cell(grid, new Box(110, 10), 0, 0);
    Grid.setColumnSpan(wide, 2);

    layOut(grid, Size(500, 400));

    assert(grid.column(0).actualWidth == 50);
    assert(grid.column(1).actualWidth == 50, "fifty each, and the ten between them makes the hundred and ten");
    assert(grid.desiredSize.width == 110);
}

unittest
{
    // A gap negative enough to out-pull the tracks takes the grid to nothing
    // rather than to a negative size -- but the placement still walks backwards,
    // because overlapping is what was asked for.
    auto grid = new Grid;
    grid.columnSpacing = -100;
    grid.addColumn(GridLength(20));
    grid.addColumn(GridLength(20));
    grid.addRow(GridLength(20));

    auto first = cell(grid, new Filler, 0, 0);
    auto second = cell(grid, new Filler, 1, 0);

    layOut(grid, Size(500, 400));

    assert(grid.desiredSize.width == 0, "a size is not negative, however hard it is pulled");
    assert(first.arrangedRect.x == 0);
    assert(second.arrangedRect.x == -80, "twenty along and a hundred back");
}
