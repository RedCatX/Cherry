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
