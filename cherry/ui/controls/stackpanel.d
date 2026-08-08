module cherry.ui.controls.stackpanel;

/*
 * A module constructor here is safe, and this is why.
 *
 * Two module constructors in one import cycle abort every binary built against
 * the framework before main() with a cyclic-dependency error that names
 * neither the import nor the property behind it.  cherry.ui.layout,
 * cherry.ui.event and cherry.ui.application each carry a banner saying so.
 *
 * What makes this module different is that its imports run one way.  It
 * imports cherry.ui.element; nothing in cherry.ui imports it back.  Its only
 * importer is cherry.ui.controls, whose only importer is cherry.ui, which
 * nothing inside the framework imports at all.  With no cycle D has an order
 * to choose -- element.d's constructor, then this one -- and that is also the
 * order the code needs, since this constructor calls Property.register and
 * getRtti!Element().
 *
 * cherry.ui.input is the working precedent: it registers three routed events
 * from a shared static this() under exactly this arrangement, and event.d's
 * banner names it as the way to do this.
 *
 * The rule every control in this package inherits: import downwards only.  A
 * control may import the element tree, the events, the input and the
 * platform.  Nothing in cherry.ui may import a control.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : Rect, Size;
import cherry.ui.element;

/**
 * The axis a panel lays its children out along.
 *
 * The member order is WPF's, so the enum's own `.init` is `horizontal` while
 * StackPanel's Orientation defaults to `vertical` -- also WPF's, and the way
 * a form is read down the page.  They disagree on purpose, as
 * HorizontalAlignment's `.init` and default already do, and for a stronger
 * reason here: nothing ever reads `Orientation.init`.  An element is given
 * the default the registration declared, and a bare Orientation variable is a
 * rarity beside a numbering every reader coming from WPF, Avalonia or WinUI
 * already knows.
 */
enum Orientation
{
    horizontal,
    vertical
}

/**
 * Lays its children out in a single line, one after another.
 *
 * Along the line every child is as long as it asked to be -- the panel
 * divides nothing up and takes nothing away, so a child's length is its own
 * business.  Across the line every child is offered the width of the panel,
 * which it fills or does not according to its own size and alignment.
 *
 * Not sealed.  WPF's is not either, and a virtualizing variant is the obvious
 * thing to derive.
 */
class StackPanel : Element
{
    shared static this()
    {
        // Which way the line runs decides what gets summed and what gets
        // maximised, so it decides the size the panel asks for.  That is the
        // dearer of the two invalidations, and it reaches the parent on its
        // own: invalidateMeasure walks up the tree.
        PropertyMetadata orientationMeta;
        orientationMeta.defaultValue = Value(Orientation.vertical);
        orientationMeta.affectsMeasure = true;

        orientationProperty = Property.register("Orientation",
            getRtti!Orientation(), getRtti!StackPanel(), orientationMeta);

        // Spacing is summed into the panel's own length, which is why it is a
        // measure and not merely an arrange: a panel that only re-arranged
        // would spread its children across a size that no longer covered
        // them, and the last one would hang out of a parent nobody told.
        PropertyMetadata spacingMeta;
        spacingMeta.defaultValue = Value(0.0f);
        spacingMeta.affectsMeasure = true;

        spacingProperty = Property.register("Spacing",
            getRtti!float(), getRtti!StackPanel(), spacingMeta, &isFiniteSpacing);
    }

    static immutable(Property) orientationProperty;
    static immutable(Property) spacingProperty;

   /**
    * The axis the children are laid out along.  Vertical by default: a stack
    * of things is a column until somebody says otherwise.
    */
    @property Orientation orientation() const
    {
        return getValue(orientationProperty).get!Orientation;
    }

    /// ditto
    @property void orientation(Orientation value)
    {
        setValue(orientationProperty, Value(value));
    }

   /**
    * Room left between neighbouring children, and only between them: n
    * children get n - 1 gaps, none before the first and none after the last.
    *
    * It adds to whatever margins the children carry rather than replacing
    * them, so in a vertical stack the distance from the bottom of one child
    * to the top of the next is its bottom margin, plus this, plus the next
    * one's top margin.  The panel never looks at a child's margin to work
    * that out -- the margin is already inside the size the child asked for,
    * and the gap simply goes on top.
    *
    * A negative spacing pulls the children together and, past zero, overlaps
    * them.  That is what a negative margin already means here, and refusing
    * one while allowing the other would be an odd rule for the same effect.
    */
    @property float spacing() const
    {
        return getValue(spacingProperty).get!float;
    }

    /// ditto
    @property void spacing(float value)
    {
        setValue(spacingProperty, Value(value));
    }

protected:
   /**
    * Offers every child all the room there could be along the line and the
    * room the panel really has across it, then adds the answers up along and
    * takes the largest across.
    *
    * The infinite offer is the question "how long would you like to be?", and
    * it is the right question: the panel divides nothing up, so a child's
    * length along the line is its own business.  Across the line the offer is
    * the truth, because that is the width the child will really be given.
    *
    * What is summed is desiredSize and not unclippedDesiredSize.  It includes
    * the child's margin, and the margin is part of what the panel is paying
    * for; along the line the cap that separates the two is a cap against what
    * was offered, and what was offered was infinity, so they agree anyway.
    * The footnote is a child with a MaxHeight of its own: there the two part
    * company, the panel follows desiredSize, and the child will overflow the
    * slot it is given.  That is right -- the child renounced the room, and the
    * panel should not ask its parent for room nobody wants.
    *
    * Nothing infinite comes back out although something infinite went in, and
    * not by luck: the panel never echoes its constraint.  Every number it
    * reports is a sum or a maximum of children's desiredSizes, and each of
    * those is finite by the contract Element.measure asserts.  With no
    * children the answer is zero.  That is what makes the case a reader
    * doubts -- a horizontal stack inside a vertical one, offered infinity on
    * both axes -- come out finite with no special case for it.
    */
    override Size measureOverride(Size availableSize)
    {
        immutable isVertical = orientation == Orientation.vertical;

        auto offer = availableSize;
        if (isVertical)
            offer.height = float.infinity;
        else
            offer.width = float.infinity;

        float along = 0;
        float across = 0;

        auto view = children;

        foreach (i; 0 .. view.length)
        {
            auto child = view[i];
            child.measure(offer);

            immutable size = child.desiredSize;

            if (isVertical)
            {
                along += size.height;
                if (size.width > across)
                    across = size.width;
            }
            else
            {
                along += size.width;
                if (size.height > across)
                    across = size.height;
            }
        }

        // n children, n - 1 gaps.  Spelled with the guard rather than as
        // (length - 1), because length is a size_t and one child would
        // otherwise buy four billion gaps.
        if (view.length > 1)
            along += spacing * (view.length - 1);

        // A spacing negative enough to out-pull the children is a direction
        // rather than a length, and a size is not negative.  Only the answer
        // is floored: arrangeOverride lets the cursor run backwards, because
        // overlapping is what was asked for.
        if (along < 0)
            along = 0;

        return isVertical ? Size(across, along) : Size(along, across);
    }

   /**
    * Places the children one after another along the line, each in a slot as
    * long as it said it needed and as wide as the panel is.
    *
    * The slot along the line is the child's own desiredSize -- the very
    * number the panel summed a moment ago, which is what makes the slots and
    * the gaps add up to exactly what the panel asked for.  It includes the
    * child's margin, and the child's own arrange takes the margin back out
    * again, so what the child ends up at is the size it wanted.
    *
    * A child too long for the room is not squeezed here either.  It is handed
    * what it asked for, Element.arrange grows any slot to at least the
    * unclipped size, and a child that outgrew the panel overflows and is seen
    * doing it.
    *
    * Across the line the extent is finalSize, and a reader arriving from WPF
    * will look for the max against the child's desired width that WPF takes
    * there.  It would be redundant here: Element.arrange has already grown
    * this size to at least the panel's own unclipped size, and for a vertical
    * stack that unclipped width is precisely the largest of the children's
    * desired widths.  So finalSize is already no smaller than any of them,
    * and the max could never change an answer.
    *
    * The rectangles are in the panel's own coordinate space, starting at
    * (0, 0): renderSubtree pushes each element's placement as a translation,
    * so a child never learns where its panel is.
    */
    override Size arrangeOverride(Size finalSize)
    {
        immutable isVertical = orientation == Orientation.vertical;
        immutable gap = spacing;

        float cursor = 0;

        auto view = children;

        foreach (i; 0 .. view.length)
        {
            // Before every child but the first, which is the whole of what
            // "between" means.  Not floored: a negative gap walking the cursor
            // backwards is the overlap that was asked for.
            if (i)
                cursor += gap;

            auto child = view[i];
            immutable size = child.desiredSize;

            if (isVertical)
            {
                child.arrange(Rect(0, cursor, finalSize.width, size.height));
                cursor += size.height;
            }
            else
            {
                child.arrange(Rect(cursor, 0, size.width, finalSize.height));
                cursor += size.width;
            }
        }

        // finalSize and not the cursor.  Element.arrange has already chosen
        // between the slot and the unclipped size according to this panel's
        // own alignment -- under stretch it is the slot, under anything else
        // it is exactly the length the children need.  Returning the cursor
        // would second-guess that, disagree with the panel's own desiredSize,
        // and break the alignment offsets that are computed from it.
        return finalSize;
    }
}

/*
 * A gap is a length, and neither infinity nor NaN is one.
 *
 * Negatives are deliberately allowed -- they overlap the children, which is
 * exactly what a negative margin already does.  What is refused is the pair
 * that would leave the panel's own answer unusable.  Either would reach the
 * sum in measureOverride and trip the finite-answer assertion inside
 * Element.measure, which would report a fault in a method the caller never
 * wrote and point at nothing.  Refusing them here names the assignment that
 * did it.
 *
 * Written as two comparisons rather than through std.math.isFinite because
 * NaN fails both of them, which is the whole point.
 */
private bool isFiniteSpacing(const(Value) value)
{
    immutable gap = value.get!float;
    return gap > -float.infinity && gap < float.infinity;
}

unittest
{
    // An enum-typed property on a control of its own, which is what the whole
    // subpackage was arranged to make possible.
    import std.exception : assertThrown;

    auto panel = new StackPanel;

    assert(panel.orientation == Orientation.vertical, "a stack is a column by default");
    assert(Orientation.init == Orientation.horizontal,
           "and the enum's own init is the other one, on purpose");
    assert(panel.getValue(StackPanel.orientationProperty).get!Orientation == Orientation.vertical);

    panel.orientation = Orientation.horizontal;
    assert(panel.orientation == Orientation.horizontal);
    assert(panel.hasLocalValue(StackPanel.orientationProperty));

    assertThrown(panel.setValue(StackPanel.orientationProperty, Value(0)));
    assert(panel.orientation == Orientation.horizontal, "and the refused write left it alone");

    panel.clearValue(StackPanel.orientationProperty);
    assert(panel.orientation == Orientation.vertical);
}

unittest
{
    // Spacing takes any length, and refuses what is not one.
    import std.exception : assertThrown;

    auto panel = new StackPanel;

    assert(panel.spacing == 0, "children touch until told otherwise");

    panel.spacing = 8;
    assert(panel.spacing == 8);

    panel.spacing = -4;
    assert(panel.spacing == -4, "a negative gap overlaps, as a negative margin does");

    assertThrown(panel.setValue(StackPanel.spacingProperty, Value(float.infinity)));
    assertThrown(panel.setValue(StackPanel.spacingProperty, Value(float.nan)));
    assert(panel.spacing == -4, "and neither refusal disturbed what was there");
}

version (unittest)
{
    import cherry.platform.render : Thickness;

   /// A child with a size of its own in both directions.
    private static class Box : Element
    {
        this(float w, float h)
        {
            width = w;
            height = h;
        }
    }

   /*
    * A child with a length of its own and no opinion across the line, which
    * is what most things in a stack are.  A Box insists on its width too, so
    * stretch cannot stretch it and centres it instead -- true, tested
    * elsewhere, and not what a test about stacking wants to be reading.
    */
    private static class Rung : Element
    {
        this(float length)
        {
            height = length;
        }
    }

    /// ditto, for a row.
    private static class Bar : Element
    {
        this(float length)
        {
            width = length;
        }
    }

   /*
    * Records the room it was offered and answers with a size fixed in
    * advance -- the half of a measure a test cannot read off the element.
    */
    private static class Probe : Element
    {
        Size seenAvailable;
        Size answer;

        this(Size answer = Size(0, 0))
        {
            this.answer = answer;
        }

        protected override Size measureOverride(Size availableSize)
        {
            seenAvailable = availableSize;
            return answer;
        }
    }

   /// Measures and arranges in one go, so no test can forget the first half.
    private void layOut(Element root, Size room)
    {
        root.measure(room);
        root.arrange(Rect(0, 0, room.width, room.height));
    }
}

unittest
{
    // A column: the lengths add up, the widest child decides the width.
    auto panel = new StackPanel;
    panel.addChild(new Box(40, 10));
    panel.addChild(new Box(70, 20));
    panel.addChild(new Box(30, 30));

    panel.measure(Size(200, 100));

    assert(panel.desiredSize == Size(70, 60), "the widest of them, and the sum of the three");
}

unittest
{
    // A row is the same thing transposed, which is the cheapest way to say
    // the two axes are not confused with each other.
    auto panel = new StackPanel;
    panel.orientation = Orientation.horizontal;
    panel.addChild(new Box(10, 40));
    panel.addChild(new Box(20, 70));
    panel.addChild(new Box(30, 30));

    panel.measure(Size(200, 100));

    assert(panel.desiredSize == Size(60, 70));
}

unittest
{
    // A child's margin is part of what it costs, so the panel pays for it in
    // both directions: along the line it lengthens the sum, across it widens
    // the widest.
    auto panel = new StackPanel;

    auto plain = new Box(40, 10);
    auto spaced = new Box(40, 20);
    spaced.margin = Thickness(5);

    panel.addChild(plain);
    panel.addChild(spaced);

    panel.measure(Size(200, 100));

    assert(panel.desiredSize == Size(50, 40),
           "40 plus ten of margin across, and 10 plus 20 plus ten of margin along");
}

unittest
{
    // Gaps go between children and nowhere else.
    auto empty = new StackPanel;
    empty.spacing = 10;
    empty.measure(Size(200, 100));
    assert(empty.desiredSize == Size(0, 0), "no children, so nothing to be between");

    auto one = new StackPanel;
    one.spacing = 10;
    one.addChild(new Box(40, 25));
    one.measure(Size(200, 100));
    assert(one.desiredSize == Size(40, 25), "one child, and still nothing to be between");

    auto three = new StackPanel;
    three.spacing = 10;
    three.addChild(new Box(40, 10));
    three.addChild(new Box(40, 20));
    three.addChild(new Box(40, 30));
    three.measure(Size(200, 100));
    assert(three.desiredSize.height == 80, "three children and two gaps, not three and not four");
}

unittest
{
    // A negative gap overlaps the children, and enough of it takes the whole
    // panel to nothing rather than to a negative size.
    auto panel = new StackPanel;
    panel.spacing = -5;
    panel.addChild(new Box(40, 20));
    panel.addChild(new Box(40, 20));

    panel.measure(Size(200, 100));
    assert(panel.desiredSize.height == 35, "two of twenty, pulled five together");

    panel.spacing = -100;
    panel.measure(Size(200, 100));
    assert(panel.desiredSize.height == 0, "a size is not negative, however hard it is pulled");
}

unittest
{
    // A child bigger than the room is reported at the room's size, because
    // that is what measure promises a parent -- and what it really wanted is
    // still on the record.
    auto panel = new StackPanel;
    panel.addChild(new Box(300, 500));

    panel.measure(Size(100, 50));

    assert(panel.desiredSize == Size(100, 50), "the parent hears only what it offered");
    assert(panel.unclippedDesiredSize == Size(100, 500),
           "the length survives; the width was already capped in the child");
}

unittest
{
    // A row inside a column, measured with an infinite height: the inner
    // panel offers its own children infinity on the other axis too, so a
    // child of it is asked an unbounded question on both.  Nothing infinite
    // comes back, and no special case says so -- the panel simply never
    // repeats its constraint.
    auto outer = new StackPanel;
    auto inner = new StackPanel;
    inner.orientation = Orientation.horizontal;

    auto probe = new Probe(Size(40, 25));
    inner.addChild(probe);
    outer.addChild(inner);

    outer.measure(Size(200, float.infinity));

    assert(probe.seenAvailable == Size(float.infinity, float.infinity),
           "asked how big it would like to be, in both directions");
    assert(inner.desiredSize == Size(40, 25));
    assert(outer.desiredSize == Size(40, 25), "and both answers are finite");
}

unittest
{
    // A column places its children top to bottom, each at its own height and
    // across the whole width of the panel.
    auto panel = new StackPanel;
    auto a = new Rung(10);
    auto b = new Rung(20);
    auto c = new Rung(30);
    panel.addChild(a);
    panel.addChild(b);
    panel.addChild(c);

    layOut(panel, Size(200, 100));

    assert(a.arrangedRect == Rect(0, 0, 200, 10));
    assert(b.arrangedRect == Rect(0, 10, 200, 20));
    assert(c.arrangedRect == Rect(0, 30, 200, 30));
}

unittest
{
    // A child with a width of its own cannot be stretched across the line, so
    // it sits in the middle of the slot the panel gave it -- which is what
    // stretch does when it cannot stretch, decided in Element and not here.
    auto panel = new StackPanel;
    auto box = new Box(40, 10);
    panel.addChild(box);

    layOut(panel, Size(200, 100));

    assert(box.arrangedRect == Rect(80, 0, 40, 10));
}

unittest
{
    // A row, left to right, transposed in every particular.
    auto panel = new StackPanel;
    panel.orientation = Orientation.horizontal;
    auto a = new Bar(10);
    auto b = new Bar(20);
    panel.addChild(a);
    panel.addChild(b);

    layOut(panel, Size(200, 100));

    assert(a.arrangedRect == Rect(0, 0, 10, 100));
    assert(b.arrangedRect == Rect(10, 0, 20, 100));
}

unittest
{
    // Spacing and margins are both gaps and they add up rather than replacing
    // each other: between these two children lie five of bottom margin, eight
    // of spacing and five of top margin.
    auto panel = new StackPanel;
    panel.spacing = 8;

    auto a = new Rung(20);
    auto b = new Rung(20);
    a.margin = Thickness(5);
    b.margin = Thickness(5);

    panel.addChild(a);
    panel.addChild(b);

    layOut(panel, Size(200, 200));

    assert(a.arrangedRect == Rect(5, 5, 190, 20), "in by its margin on every side");
    assert(b.arrangedRect.y == 5 + 20 + 5 + 8 + 5, "bottom margin, gap, top margin");
    assert(b.arrangedRect.y - (a.arrangedRect.y + a.arrangedRect.height) == 18);
}

unittest
{
    // A child that outgrew the panel pushes the next one along rather than
    // being absorbed: overflow that shows is overflow that gets fixed.
    auto panel = new StackPanel;
    auto big = new Box(300, 500);
    auto after = new Box(40, 20);
    panel.addChild(big);
    panel.addChild(after);

    layOut(panel, Size(100, 50));

    assert(big.actualHeight == 500, "arranged at what it needed, not at what fitted");
    assert(big.actualWidth == 300);
    assert(after.arrangedRect.y == 500, "and the next child starts below all of it");
}

unittest
{
    // Across the line a child fills the panel unless it has a width of its
    // own; the panel places it, and its own alignment positions it inside
    // what it was given.  The two do not fight.
    auto panel = new StackPanel;
    auto filling = new Element;
    auto sized = new Box(50, 20);
    sized.horizontalAlignment = HorizontalAlignment.right;

    panel.addChild(filling);
    panel.addChild(sized);

    layOut(panel, Size(200, 100));

    assert(filling.actualWidth == 200, "nothing of its own to insist on, so it takes the width");
    assert(sized.arrangedRect == Rect(150, filling.actualHeight, 50, 20),
           "pushed to the right edge of the slot the panel gave it, at the stacking cursor");
}

unittest
{
    // A negative gap walks the cursor backwards, which is the overlap that
    // was asked for -- unlike the reported size, this is not floored.
    auto panel = new StackPanel;
    panel.spacing = -10;
    auto a = new Box(40, 30);
    auto b = new Box(40, 30);
    panel.addChild(a);
    panel.addChild(b);

    layOut(panel, Size(200, 200));

    assert(a.arrangedRect.y == 0);
    assert(b.arrangedRect.y == 20, "thirty down, ten back");
}

unittest
{
    // An empty panel lays out without complaint and takes the room it was
    // given.
    auto panel = new StackPanel;

    layOut(panel, Size(200, 100));

    assert(panel.actualWidth == 200 && panel.actualHeight == 100);
    assert(panel.desiredSize == Size(0, 0));
}

unittest
{
    // Both properties change how much the panel asks for, so both invalidate
    // the measure -- and the parent hears about it, because invalidateMeasure
    // walks up on its own.
    auto parent = new Element;
    auto panel = new StackPanel;
    parent.addChild(panel);
    panel.addChild(new Box(40, 20));

    void settle()
    {
        panel.invalidateMeasure();
        parent.measure(Size(500, 400));
        parent.arrange(Rect(0, 0, 500, 400));
        assert(panel.isMeasureValid && panel.isArrangeValid);
        assert(parent.isMeasureValid && parent.isArrangeValid);
    }

    settle();
    panel.orientation = Orientation.horizontal;
    assert(!panel.isMeasureValid && !panel.isArrangeValid);
    assert(!parent.isMeasureValid, "which way the line runs changes what it costs");

    settle();
    panel.spacing = 12;
    assert(!panel.isMeasureValid);
    assert(!parent.isMeasureValid, "and so does the room between the children");
}
