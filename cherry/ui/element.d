module cherry.ui.element;

import cherry.core.obj;

/**
 * Base class for every node of the element tree.
 *
 * The tree models visual containment -- the analogue of Delphi's
 * TControl.Parent, not TComponent.Owner.  Routed events, property value
 * inheritance, style lookup, layout and rendering all traverse this tree.
 * Non-visual property-bearing objects (fonts, brushes, styles) remain plain
 * CherryObjects and never enter it.
 *
 * Invariants maintained by the mutation methods:
 *   - a child's parent is always the element whose child list contains it;
 *   - an element can have at most one parent (detach before re-adding);
 *   - the tree is acyclic (an ancestor cannot become a child).
 */
class Element : CherryObject
{
   /**
    * The element this one is parented to, or null for a tree root.
    */
    @property inout(Element) parent() inout pure nothrow @nogc
    {
        return _parent;
    }

   /**
    * The topmost ancestor; the element itself when it has no parent.
    */
    @property Element root() pure nothrow @nogc
    {
        Element e = this;
        while (e._parent !is null)
            e = e._parent;
        return e;
    }

   /**
    * Number of direct children.
    */
    @property size_t childCount() const pure nothrow @nogc
    {
        return _children.length;
    }

   /**
    * Read-only, indexable forward range over the direct children.
    * The view is a snapshot of the current child list; structural changes
    * made after obtaining it are not reflected in the view.
    */
    @property ChildrenView children() pure nothrow @nogc
    {
        return ChildrenView(_children);
    }

   /**
    * Appends a child to the end of the child list.
    */
    void addChild(Element child)
    {
        insertChild(_children.length, child);
    }

   /**
    * Inserts a child at the given position in the child list.
    *
    * Throws: Exception when child is null, already parented, would create a
    * cycle, or index is out of range.
    */
    void insertChild(size_t index, Element child)
    {
        if (child is null)
            throw new Exception("Cannot add a null child.");
        if (child._parent is this)
            throw new Exception("The element is already a child of this element.");
        if (child._parent !is null)
            throw new Exception("The element already has a parent; detach it from its current parent first.");
        if (child is this || child.isAncestorOf(this))
            throw new Exception("Adding this element would create a cycle in the tree.");
        if (index > _children.length)
            throw new Exception("Child index is out of range.");

        _children = _children[0 .. index] ~ child ~ _children[index .. $];
        child._parent = this;
        child.onAttached(this);
    }

   /**
    * Removes a direct child.  The child keeps its own subtree.
    *
    * Throws: Exception when the element is not a direct child of this one.
    */
    void removeChild(Element child)
    {
        if (child is null || child._parent !is this)
            throw new Exception("The element is not a child of this element.");

        foreach (i, c; _children)
        {
            if (c is child)
            {
                _children = _children[0 .. i] ~ _children[i + 1 .. $];
                break;
            }
        }

        child._parent = null;
        child.onDetached(this);
    }

   /**
    * Detaches every direct child.  Each child keeps its own subtree.
    */
    void clearChildren()
    {
        auto detached = _children;
        _children = null;

        foreach (child; detached)
        {
            child._parent = null;
            child.onDetached(this);
        }
    }

   /**
    * Removes this element from its parent.  Does nothing for a tree root.
    */
    void detach()
    {
        if (_parent !is null)
            _parent.removeChild(this);
    }

   /**
    * Whether this element is a (transitive) ancestor of the given one.
    * An element is not considered its own ancestor.
    */
    final bool isAncestorOf(scope const(Element) descendant) const pure nothrow @nogc
    {
        // Recursion instead of a loop: a const class reference cannot be
        // rebound, so walking the chain iteratively would need Rebindable.
        if (descendant is null || descendant._parent is null)
            return false;
        if (descendant._parent is this)
            return true;
        return isAncestorOf(descendant._parent);
    }

   /**
    * Whether this element is a (transitive) descendant of the given one.
    */
    final bool isDescendantOf(scope const(Element) ancestor) const pure nothrow @nogc
    {
        return ancestor !is null && ancestor.isAncestorOf(this);
    }

   /**
    * Forward range walking the parent chain from the immediate parent to the
    * tree root.  Used by property value inheritance and event routing.
    */
    auto ancestors() pure nothrow @nogc
    {
        return AncestorRange(_parent);
    }

   /**
    * Input range over the whole subtree below this element in depth-first
    * pre-order (children visited left to right).  Excludes the element
    * itself.  The tree must not be mutated while iterating.
    */
    auto descendants() pure nothrow
    {
        DescendantRange r;
        foreach_reverse (child; _children)
            r._stack ~= child;
        return r;
    }

protected:
   /**
    * Called on the element right after it has been added to a parent.
    * Inherited-property and style invalidation will hook in here later.
    */
    void onAttached(Element parent)
    {
    }

   /**
    * Called on the element right after it has been removed from a parent.
    */
    void onDetached(Element oldParent)
    {
    }

private:
    Element   _parent;
    Element[] _children;
}

/**
 * Read-only, indexable forward range over an element's children.
 */
struct ChildrenView
{
    @property size_t length() const pure nothrow @nogc
    {
        return _items.length;
    }

    @property bool empty() const pure nothrow @nogc
    {
        return _items.length == 0;
    }

    @property Element front() pure nothrow @nogc
    {
        return _items[0];
    }

    void popFront() pure nothrow @nogc
    {
        _items = _items[1 .. $];
    }

    @property ChildrenView save() pure nothrow @nogc
    {
        return this;
    }

    Element opIndex(size_t index) pure nothrow @nogc
    {
        return _items[index];
    }

    size_t opDollar() const pure nothrow @nogc
    {
        return _items.length;
    }

    private Element[] _items;
}

/**
 * Forward range over an element's ancestors, nearest first.
 */
struct AncestorRange
{
    @property bool empty() const pure nothrow @nogc
    {
        return _current is null;
    }

    @property Element front() pure nothrow @nogc
    {
        return _current;
    }

    void popFront() pure nothrow @nogc
    {
        _current = _current._parent;
    }

    @property AncestorRange save() pure nothrow @nogc
    {
        return this;
    }

    private Element _current;
}

/**
 * Input range performing a depth-first pre-order walk of a subtree.
 */
struct DescendantRange
{
    @property bool empty() const pure nothrow @nogc
    {
        return _stack.length == 0;
    }

    @property Element front() pure nothrow @nogc
    {
        return _stack[$ - 1];
    }

    void popFront() pure nothrow
    {
        auto node = _stack[$ - 1];
        _stack = _stack[0 .. $ - 1];

        foreach_reverse (child; node._children)
            _stack ~= child;
    }

    private Element[] _stack;
}

unittest
{
    import std.exception : assertThrown;
    import std.algorithm : equal;

    auto root = new Element;
    auto a = new Element;
    auto b = new Element;
    auto c = new Element;

    root.addChild(a);
    root.addChild(b);
    a.addChild(c);

    // Structure
    assert(root.parent is null);
    assert(a.parent is root);
    assert(b.parent is root);
    assert(c.parent is a);
    assert(root.childCount == 2);
    assert(root.children[0] is a);
    assert(root.children[1] is b);
    assert(root.children[$ - 1] is b);
    assert(c.root is root);
    assert(root.root is root);

    // Invariants
    assertThrown(root.addChild(null));   // null child
    assertThrown(root.addChild(a));      // already a child of this element
    assertThrown(b.addChild(a));         // already parented elsewhere
    assertThrown(c.addChild(root));      // would create a cycle
    {
        auto solo = new Element;
        assertThrown(solo.addChild(solo)); // self as child
    }
    assertThrown(root.removeChild(c));   // not a direct child
    assertThrown(root.removeChild(null));

    // Traversal
    assert(c.ancestors.equal([a, root]));
    assert(root.ancestors.empty);
    assert(root.descendants.equal([a, c, b])); // depth-first pre-order
    assert(c.descendants.empty);

    // Ancestry predicates
    assert(root.isAncestorOf(c));
    assert(root.isAncestorOf(a));
    assert(!c.isAncestorOf(root));
    assert(!root.isAncestorOf(root));
    assert(c.isDescendantOf(root));
    assert(!root.isDescendantOf(c));
    assert(!root.isAncestorOf(null));

    // Removal clears the parent link but keeps the child's subtree
    root.removeChild(b);
    assert(b.parent is null);
    assert(root.childCount == 1);
    assert(c.parent is a); // untouched

    // detach()
    c.detach();
    assert(c.parent is null);
    assert(a.childCount == 0);
    c.detach(); // no-op on a root

    // insertChild ordering
    root.insertChild(0, b);
    assert(root.children[0] is b);
    assert(root.children[1] is a);
    assertThrown(root.insertChild(5, c)); // index out of range

    // clearChildren detaches every child
    root.addChild(c);
    root.clearChildren();
    assert(root.childCount == 0);
    assert(a.parent is null);
    assert(b.parent is null);
    assert(c.parent is null);
}

unittest
{
    // Attach/detach hooks fire after the state change, with the right peer.
    static class Probe : Element
    {
        int attachedCount;
        int detachedCount;
        Element seenParent;
        Element seenOldParent;
        bool parentWasSetInHook;

        protected override void onAttached(Element parent)
        {
            attachedCount++;
            seenParent = parent;
            parentWasSetInHook = (this.parent is parent);
        }

        protected override void onDetached(Element oldParent)
        {
            detachedCount++;
            seenOldParent = oldParent;
        }
    }

    auto host = new Element;
    auto probe = new Probe;

    host.addChild(probe);
    assert(probe.attachedCount == 1);
    assert(probe.seenParent is host);
    assert(probe.parentWasSetInHook); // state updated before the hook runs

    host.removeChild(probe);
    assert(probe.detachedCount == 1);
    assert(probe.seenOldParent is host);
    assert(probe.parent is null);

    host.addChild(probe);
    probe.detach();
    assert(probe.attachedCount == 2);
    assert(probe.detachedCount == 2);

    // clearChildren also fires the hook
    host.addChild(probe);
    host.clearChildren();
    assert(probe.detachedCount == 3);
}
