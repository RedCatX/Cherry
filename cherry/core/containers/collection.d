/**
 * Provides $(D Collection) - a dynamically sized, type-checked container of
 * $(D Value) instances.
 *
 * Every item stored in a collection must be assignable to the item type given
 * at construction time; an attempt to store anything else throws. All mutating
 * operations raise a protected callback ($(D onItemAdded), $(D onItemMoved),
 * $(D onBeforeItemRemoved), $(D onItemChanged), $(D onClear)), so derived classes
 * can observe changes without re-implementing the storage itself.
 *
 * The class is intended to be subclassed in order to provide a statically typed
 * facade over the $(D Value)-based interface - see the unittests below for an
 * example.
 */
module cherry.core.containers.collection;

import cherry.core.value;
import cherry.core.rtti;

/**
 * A collection of values of a specific type.
 *
 * The collection owns a plain array of $(D Value) and keeps its items in
 * insertion order. Indices are always in the range $(D [0 .. length)) and are
 * invalidated by any operation that adds, removes or moves items.
 */
class Collection
{
    /// A collection cannot be created without an item type.
    @disable this();

    /**
     * Creates a new collection of values of the specified type.
     *
     * Params:
     *   itemRtti = Runtime type information of the items this collection is
     *              allowed to store. Values of any type assignable to it (e.g.
     *              subclasses) are accepted as well.
     */
    this(immutable(Rtti) itemRtti)
    {
        _itemRtti = itemRtti;
    }

    /**
     * Returns the Rtti of the items stored in this collection.
     *
     * Returns:
     *   The item type passed to the constructor. It never changes during the
     *   lifetime of the collection.
     */
    @property immutable(Rtti) itemRtti() pure const nothrow @nogc
    {
        return _itemRtti;
    }

    /**
     * Returns the number of items in this collection.
     *
     * Returns:
     *   The item count, or 0 for an empty collection.
     */
    @property size_t length() pure const nothrow @nogc
    {
        return _container.length;
    }

    /**
     * Returns the first item in this collection.
     *
     * Returns:
     *   The item at index 0, or $(D Value.init) if the collection is empty.
     */
    @property Value front() const
    {
        if (_container.length > 0)
            return Value(_container[0]);
        else
            return Value.init;
    }

    /**
     * Returns the last item in this collection.
     *
     * Returns:
     *   The item at index $(D length - 1), or $(D Value.init) if the collection
     *   is empty.
     */
    @property Value back() const 
    {
        if (_container.length > 0)
            return Value(_container[_container.length - 1]);
        else
            return Value.init;
    }

    /**
     * Returns true if this collection is empty, false otherwise.
     *
     * Returns:
     *   $(D true) when $(D length == 0).
     */
    @property bool empty() pure const nothrow @nogc
    {
        return (_container.length == 0);
    }

    /**
     * Returns the item at the specified index.
     *
     * Params:
     *   index = The index of the item to retrieve. Must be less than $(D length).
     *
     * Returns:
     *   The item at the specified index.
     */
    Value item(size_t index) const
    in {
        assert(index < _container.length);
    }     
    do {
        return Value(_container[index]);
    }

    /**
     * Sets the item at the specified index.
     *
     * The new value is type-checked against $(D itemRtti) before it replaces
     * the old one. On success $(D onItemChanged) is called.
     *
     * Params:
     *   index = The index of the item to set. Must be less than $(D length).
     *   value = The new value to set.
     *
     * Returns:
     *   The value that was set.
     *
     * Throws:
     *   $(D Exception) if $(D value) is not assignable to $(D itemRtti); in that
     *   case the collection is left unchanged.
     */
    Value set(size_t index, Value value)
    in {
        assert(index < _container.length);
    }
    do {
        validateValue(value);

        _container[index] = value;
        onItemChanged(index);
        return value;
    }

    /**
     * Appends an item to the end of this collection.
     *
     * The item is type-checked against $(D itemRtti) before it is stored. On
     * success $(D onItemAdded) is called with the index of the new item.
     *
     * Params:
     *   item = The value to append.
     *
     * Returns:
     *   The index of the appended item, i.e. the length the collection had
     *   before the call.
     *
     * Throws:
     *   $(D Exception) if $(D item) is not assignable to $(D itemRtti); in that
     *   case the collection is left unchanged.
     */
    size_t add(Value item)
    {
        validateValue(item);

        size_t index = _container.length;

        _container.length++;
        _container[index] = item;
        onItemAdded(index);

        return index; 
    }

    /**
     * Inserts an item at the specified position, shifting all following items
     * one position to the right.
     *
     * Params:
     *   item  = The value to insert.
     *   index = The position the item should occupy afterwards. Must not be
     *           greater than $(D length); passing $(D length) behaves like
     *           $(D add).
     *
     * Returns:
     *   The index at which the item was inserted (the same value as $(D index)).
     *
     * Throws:
     *   $(D Exception) if $(D item) is not assignable to $(D itemRtti); in that
     *   case the collection is left unchanged.
     */
    size_t insert(Value item, size_t index)
    in {
        assert(index <= _container.length);
    }
    do {
        validateValue(item);

        _container.length++;

        foreach_reverse (i; index .. _container.length - 1)
            _container[i + 1] = _container[i];

        _container[index] = item;
         onItemAdded(index);

        return index;
    }

    /**
     * Moves an item to another position within this collection.
     *
     * The items between the old and the new position are shifted by one
     * position so that no gap appears and no item is lost. Afterwards
     * $(D onItemMoved) is called.
     *
     * Params:
     *   oldIndex = The current index of the item to move.
     *   newIndex = The index the item should have afterwards.
     *
     * Returns:
     *   The new index of the moved item (the same value as $(D newIndex)).
     */
    size_t move(size_t oldIndex, size_t newIndex)
    in {
        assert(oldIndex < _container.length);
        assert(newIndex < _container.length);
    }
    do {
        if (oldIndex == newIndex)
            return newIndex;

        Value curItem = _container[oldIndex];

        if (newIndex > oldIndex)
        {
            // shift (oldIndex .. newIndex] one position to the left
            foreach (i; oldIndex .. newIndex)
                _container[i] = _container[i + 1];
        }
        else
        {
            // shift [newIndex .. oldIndex) one position to the right
            foreach_reverse (i; newIndex .. oldIndex)
                _container[i + 1] = _container[i];
        }

        _container[newIndex] = curItem;
        onItemMoved(oldIndex, newIndex);

        return newIndex;
    }

    /**
     * Removes the item at the specified index, shifting all following items one
     * position to the left.
     *
     * Before the item is dropped $(D onBeforeItemRemoved) is called; at that
     * point the collection is still intact, so the item being removed is
     * available via $(D item(index)).
     *
     * Params:
     *   index = The index of the item to remove. Must be less than $(D length).
     */
    void remove(size_t index)
    in {
        assert(index < _container.length);
    }
    do {
        onBeforeItemRemoved(index);

        for (size_t i = index; i < _container.length - 1; i++)
            _container[i] = _container[i+1];

        _container.length--;
    }

    /**
     * Removes the last item of this collection.
     *
     * Does nothing if the collection is already empty. Otherwise behaves
     * exactly like $(D remove(length - 1)) and therefore raises
     * $(D onBeforeItemRemoved).
     */
    void removeBack()
    {
        if (_container.length > 0)
            remove(_container.length - 1);
    }

    /**
     * Removes all items from this collection at once.
     *
     * $(D onBeforeItemRemoved) is called once for every item, in ascending
     * index order, while the collection is still fully populated - the indices
     * passed to it therefore refer to the original layout and do not shift
     * between the calls. Nothing is raised for an already empty collection.
     */
    void clear()
    {
        if (!empty) 
        {
            for (size_t i = 0; i < _container.length; i++)
                onBeforeItemRemoved(i);

            _container.length = 0;
            onClear();
        }
    }

protected:
    /**
    * Called when the collection is cleared.
    *
    * At the time of the call the collection is already empty. The default
    * implementation does nothing.
    */
    void onClear()
    {
    }

    /**
     * Called when an item is added to the collection.
     *
     * Raised by both $(D add) and $(D insert), after the item has been stored at
     * its final position. The default implementation does nothing.
     *
     * Params:
     *   index = The index of the item that was added.
     */
    void onItemAdded(size_t index)
    {
    }

    /**
     * Called when an item is moved within the collection.
     *
     * Raised by $(D move) after the item and all items in between have been
     * shifted. The default implementation does nothing.
     *
     * Params:
     *   oldIndex = The index of the item before it was moved.
     *   newIndex = The index of the item after it was moved.
     */
    void onItemMoved(size_t oldIndex, size_t newIndex)
    {
    }

    /**
     * Called before an item is removed from the collection.
     *
     * Raised by $(D remove), $(D removeBack) and $(D clear) while the item is
     * still stored, so a derived class can inspect or release it via
     * $(D item(index)). The callback cannot cancel the removal; throwing from
     * it aborts the operation and leaves the collection unchanged.
     * The default implementation does nothing.
     *
     * Params:
     *   index = The index of the item that is about to be removed.
     */
    void onBeforeItemRemoved(size_t index)
    {
    }

    /**
     * Called when an item is changed by set() or [] operator.
     *
     * Raised after the new value has been stored. The default implementation
     * does nothing.
     *
     * Params:
     *   index = The index of the item that was changed
     */
    void onItemChanged(size_t index)
    {
    }

private:
    void validateValue(Value v)
    {
        if (!_itemRtti.isAssignableFrom(v.typeinfo))
            throw new Exception("This collection cannot store an element of " ~ v.typeinfo.toString() ~ " type");
    }

    Value[] _container;
    immutable(Rtti) _itemRtti;
}

/// Basic operations on a collection of ints.
unittest
{
    import std.exception : assertThrown;

    Collection c = new Collection(getRtti!int);
    
    // new collection is empty
    assert(c.empty);
    assert(c.front.empty);
    assert(c.back.empty);
    assert(c.length == 0);
    
    // add items tho the collection
    c.add(Value(1));
    c.add(Value(2));
    c.add(Value(5));
    assert(c.length == 3);
    assert(!c.empty);
    assert(c.item(0) == 1);
    assert(c.item(1) == 2);
    assert(c.item(2) == 5);

    // Add wrong value
    assertThrown(
        c.add(Value("text"))
    );
    
    // insert items to the collection
    assert(c.insert(Value(3), 2) == 2);
    assert(c.insert(Value(4), 3) == 3);
    assert(c.insert(Value(6), 5) == 5);
    assert(c.insert(Value(0), 0) == 0);
    assert(c.length == 7);
    assert(!c.empty);
    assert(c.item(0) == 0);
    assert(c.item(1) == 1);
    assert(c.item(2) == 2);
    assert(c.item(3) == 3);
    assert(c.item(4) == 4);
    assert(c.item(5) == 5);
    assert(c.item(6) == 6);

    // Insert wrong value
    assertThrown(
        c.insert(Value("text"), 3)
    );

    // move item to right
    assert(c.move(0, 4) == 4);
    assert(c.item(0) == 1);
    assert(c.item(1) == 2);
    assert(c.item(2) == 3);
    assert(c.item(3) == 4);
    assert(c.item(4) == 0);
    assert(c.item(5) == 5);
    assert(c.item(6) == 6);

    // move item to left
    assert(c.move(4, 0) == 0);
    assert(c.item(0) == 0);
    assert(c.item(1) == 1);
    assert(c.item(2) == 2);
    assert(c.item(3) == 3);
    assert(c.item(4) == 4);
    assert(c.item(5) == 5);
    assert(c.item(6) == 6);

    // remove first item
    c.remove(0);
    assert(c.length == 6);
    assert(c.item(0) == 1);
    assert(c.item(1) == 2);
    assert(c.item(2) == 3);
    assert(c.item(3) == 4);
    assert(c.item(4) == 5);
    assert(c.item(5) == 6);

    // remove last item
    c.removeBack;
    assert(c.length == 5);
    assert(c.item(0) == 1);
    assert(c.item(1) == 2);
    assert(c.item(2) == 3);
    assert(c.item(3) == 4);
    assert(c.item(4) == 5);

    // remove middle item
    c.remove(2);
    assert(c.length == 4);
    assert(c.item(0) == 1);
    assert(c.item(1) == 2);
    assert(c.item(2) == 4);
    assert(c.item(3) == 5);

    // set item
    assert(c.set(0, Value(10)).get!int == 10);
    assert(c.item(0) == 10);
    assert(c.item(1) == 2);
    assert(c.item(2) == 4);
    assert(c.item(3) == 5);

    // Set wrong value
    assertThrown(
        c.set(2, Value("text"))
    );

    // clear collection
    c.clear();
    assert(c.empty);
    assert(c.front.empty);
    assert(c.back.empty);
    assert(c.length == 0);
}

/// Subclassing Collection: a typed facade plus change notifications.
unittest
{
    class Test
    {
        this(int d) { data = d; }
        int data;
    }

    class TestCollection : Collection
    {        
        this() { super(getRtti!Test); }

        Test test(size_t index) const         { return super.item(index).get!Test; }
        Test set(size_t index, Test val)      { return super.set(index, Value(val)).get!Test; }
        size_t add(Test val)                  { return super.add(Value(val)); }
        size_t insert(Test val, size_t index) { return super.insert(Value(val), index); }

        Test opIndex(size_t i) const          { return test(i); }
        Test opIndexAssign(Test v, size_t i)  { set(i, v); return v; }

        @property long index() const { return _index; } 
        @property long oldIndex() const { return _oldIndex; }
        @property uint addedItemsCount() const { return _addedItemsCount; }
        @property uint removedItemsCount() const { return _removedItemsCount; }
        @property uint movedItemsCount() const { return _movedItemsCount; }
        @property uint changedItemsCount() const { return _changedItemsCount; }

    protected:
        override void onItemAdded(size_t index)
        {
            _addedItemsCount++;
            _index = index; 
        }

        override void onItemMoved(size_t oldIndex, size_t newIndex)
        {
            _movedItemsCount++;
            _oldIndex = oldIndex;
            _index = newIndex;
        }

        override void onBeforeItemRemoved(size_t index)
        {
            _removedItemsCount++;
            _index = index;
        }

        override void onItemChanged(size_t index)
        {
            _changedItemsCount++;
            _index = index;
        }

    private:
        long _index = -1;
        long _oldIndex = -1;
        uint _addedItemsCount = 0;
        uint _removedItemsCount = 0;
        uint _movedItemsCount = 0;
        uint _changedItemsCount = 0;
    }

    TestCollection c = new TestCollection;

    /// collection is empty
    assert(c.empty);
    assert(c.length == 0);

    /// collection changes callback test
    c.add(new Test(10));
    assert(c.length == 1);
    assert(c.addedItemsCount == 1);
    assert(c.index == 0);
    c.add(new Test(20));
    c.add(new Test(30));
    c.add(new Test(40));
    assert(c.length == 4);
    assert(c.index == 3);
    c.remove(0);
    assert(c.length == 3);
    assert(c.index == 0);
    c.move(0, 2);
    assert(c.length == 3);
    assert(c.oldIndex == 0);
    assert(c.index == 2);
    c.removeBack();
    assert(c.length == 2);
    assert(c.index == 2);
    assert(c.addedItemsCount == 4);
    assert(c.movedItemsCount == 1);
    assert(c.removedItemsCount == 2);
    
    /// collection item set callback test
    assert(c.changedItemsCount == 0);
    // getting the element should not raise callback
    Test t = c[0];
    assert(t.data == 30);
    assert(c.changedItemsCount == 0);
    // assigning an element by index should raise callback
    c[0] = t;
    assert(c.changedItemsCount == 1);
    assert(c.index == 0);
    c[1] = new Test(100);
    assert(c.changedItemsCount == 2);
    assert(c.index == 1);
    assert(c[1].data == 100);

    /// clear collection callback test
    c.clear();
    assert(c.empty);
    assert(c.length == 0);
    assert(c.removedItemsCount == c.addedItemsCount);
}