module cherry.ui.styledelement;

/*
 * No module constructor here, ever.
 *
 * Everything in cherry.ui sits on top of this module, and element.d -- which
 * has one -- is in an import cycle with layout.d.  A second constructor
 * reachable from that cycle aborts every binary built against the framework
 * before main(), with a cyclic-dependency error that names neither the import
 * nor the property behind it.  layout.d and event.d carry the same banner.
 *
 * A property registered on StyledElement therefore has to be registered from
 * element.d's constructor, or this module has to stay out of the cycle.  The
 * second is what visual.d does, and the note there explains how.
 */

import cherry.core.obj;

/**
 * The layer that carries what an object is *told* to look like: styles,
 * resources, the data context, bindings -- and the logical tree those walk.
 *
 * None of that exists yet.  What is here today is the seam they all need, and
 * the one member already built on it: property value inheritance walks the
 * logical parent, and so will resource lookup upwards and DataContext
 * downwards when they arrive.
 *
 * **Why this sits below Visual** (Avalonia's placement, not WPF's): neither
 * walk needs the walker to be visual.  A resource dictionary on a style, a
 * binding source on a non-visual object, an item in a collection that has not
 * been realised into anything on the screen -- all of them take part in this
 * layer and none of them draw.  Putting it under Visual is what will let them.
 *
 * **The logical tree is not stored here yet, and that is not a lie.** Today
 * every node of the logical tree is an Element, and Element's tree is the only
 * tree there is, so it answers `logicalParent` from it.  The two part company
 * when control templates arrive -- a button's border and its text are visual
 * children of the button and logical children of nobody -- and on that day the
 * storage moves here, with no change at any call site.
 */
class StyledElement : CherryObject
{
   /**
    * The node above this one in the logical tree, or null at its top.
    *
    * Public and virtual because it is the tree's navigation API, in the way
    * WPF spells it `LogicalTreeHelper.GetParent`.  It cannot be `package`
    * even though only the framework answers it today: D makes a `package`
    * method non-virtual, so an override would be silently ignored and the
    * chain would stop at every level.
    */
    @property inout(StyledElement) logicalParent() inout
    {
        return null;
    }

protected:
   /**
    * Inherited property values flow down the logical tree.
    *
    * This is the whole of what connects the property store to a tree, and it
    * is expressed once, here, rather than in each layer that happens to have
    * one.  CherryObject asks; the logical tree answers.
    *
    * `logicalParent` is `inout` precisely so this can be written without a
    * cast: the readers in CherryObject are const, and a walk that had to cast
    * its own constness away to take one step would be a walk nobody could
    * trust.
    */
    override @property const(CherryObject) inheritanceParent() const
    {
        return logicalParent;
    }
}

unittest
{
    // The seam on its own, with no element tree under it.
    //
    // Element has the tree today and its own test walks inheritance through it,
    // which is the case that matters in practice.  This one is the case that
    // matters to the design: a StyledElement that is not an Element, chained by
    // nothing but logicalParent, inherits all the same.  It is what says the
    // walk belongs to this layer rather than to the element tree that currently
    // supplies it -- and it is written here without importing element.d, which
    // would put this module in the import cycle the banner above is about.
    import cherry.core.property;
    import cherry.core.rtti;
    import cherry.core.value;

    static class Node : StyledElement
    {
        Node above;

        override @property inout(StyledElement) logicalParent() inout
        {
            return above;
        }
    }

    PropertyMetadata meta;
    meta.defaultValue = Value(10);
    meta.inherits = true;
    auto sizeProperty = Property.register("styledInheritedSize",
        getRtti!int(), getRtti!Node(), meta);

    auto root  = new Node;
    auto inner = new Node;
    auto leaf  = new Node;
    inner.above = root;
    leaf.above = inner;

    assert(leaf.getValue(sizeProperty).get!int == 10, "nobody has said otherwise");

    root.setValue(sizeProperty, Value(20));
    assert(leaf.getValue(sizeProperty).get!int == 20, "across two levels");
    assert(!leaf.hasLocalValue(sizeProperty));

    inner.setValue(sizeProperty, Value(30));
    assert(leaf.getValue(sizeProperty).get!int == 30, "and the nearest one wins");

    // Breaking the chain is breaking the inheritance -- the walk is the
    // logical parent and nothing else.
    inner.above = null;
    assert(leaf.getValue(sizeProperty).get!int == 30);
    inner.clearValue(sizeProperty);
    assert(leaf.getValue(sizeProperty).get!int == 10, "cut off from root");
}
