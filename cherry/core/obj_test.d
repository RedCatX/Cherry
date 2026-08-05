module cherry.core.obj_test;

// This module lives outside the property/obj import cycle: the core modules
// do not import it back, so its static constructor is free to run after
// theirs.  That lets the sample control register its properties in a
// `shared static this`, exactly as a real control would.

version (unittest):

import cherry.core.obj;
import cherry.core.rtti;
import cherry.core.value;
import cherry.core.property;
import cherry.core.multicast;

import std.exception : assertThrown;

/**
 * A sample CherryObject subclass that registers its dependency properties in a
 * static constructor -- the idiomatic pattern for real controls.
 */
final class Widget : CherryObject
{
    shared static this()
    {
        PropertyMetadata widthMeta;
        widthMeta.defaultValue = Value(100);
        widthMeta.onCoerceValue = &clampNonNegative;
        widthMeta.onPropertyChanged ~= &onWidthChanged;

        widthProperty = Property.register("Width", getRtti!int(), getRtti!Widget(), widthMeta);

        // A coerce callback that returns the wrong type, so that the check on
        // its result has something to catch.
        PropertyMetadata strayMeta;
        strayMeta.defaultValue = Value(0);
        strayMeta.onCoerceValue = &coerceToText;
        strayProperty = Property.register("Stray", getRtti!int(), getRtti!Widget(), strayMeta);
        titleProperty = Property.register("Title", getRtti!string(), getRtti!Widget());
        evenProperty  = Property.register("Even", getRtti!int(), getRtti!Widget(),
                                          PropertyMetadata.init, &isEven);
    }

    static immutable(Property) widthProperty;
    static immutable(Property) titleProperty;
    static immutable(Property) evenProperty;
    static immutable(Property) strayProperty;
}

private int widthChangedCount;

private Value clampNonNegative(Object, Value v)
{
    return v.get!int < 0 ? Value(0) : v;
}

private Value coerceToText(Object, Value)
{
    return Value("not a number");
}

private bool isEven(const(Value) v)
{
    return (v.get!int & 1) == 0;
}

private void onWidthChanged(const(Object), const(Value), const(Value))
{
    widthChangedCount++;
}

unittest
{
    auto w = new Widget;

    // An unset property returns its default.
    assert(w.getValue(Widget.widthProperty).get!int == 100);
    assert(!w.hasLocalValue(Widget.widthProperty));

    // Setting a value stores it and fires the change handler once.
    widthChangedCount = 0;
    w.setValue(Widget.widthProperty, Value(250));
    assert(w.getValue(Widget.widthProperty).get!int == 250);
    assert(w.hasLocalValue(Widget.widthProperty));
    assert(widthChangedCount == 1);

    // Setting the same effective value again does not fire the handler.
    w.setValue(Widget.widthProperty, Value(250));
    assert(widthChangedCount == 1);

    // Coercion clamps a negative width to zero.
    w.setValue(Widget.widthProperty, Value(-5));
    assert(w.getValue(Widget.widthProperty).get!int == 0);

    // clearValue reverts to the default.
    w.clearValue(Widget.widthProperty);
    assert(w.getValue(Widget.widthProperty).get!int == 100);
    assert(!w.hasLocalValue(Widget.widthProperty));

    // A type mismatch is rejected.
    assertThrown(w.setValue(Widget.titleProperty, Value(42)));

    // The validator rejects odd numbers but accepts even ones.
    assertThrown(w.setValue(Widget.evenProperty, Value(3)));
    w.setValue(Widget.evenProperty, Value(4));
    assert(w.getValue(Widget.evenProperty).get!int == 4);

    // Separate instances keep independent stores.
    auto w2 = new Widget;
    w.setValue(Widget.widthProperty, Value(10));
    assert(w2.getValue(Widget.widthProperty).get!int == 100);
}

unittest
{
    // A coerce callback is held to the same rule as the caller.  Without the
    // check its result would go straight into the store, and the mistake would
    // only be heard about at the next read of the property -- by which point
    // nothing points back at the coercion.
    auto w = new Widget;

    assertThrown(w.setValue(Widget.strayProperty, Value(1)));

    assert(!w.hasLocalValue(Widget.strayProperty), "and nothing was stored");
    assert(w.getValue(Widget.strayProperty).get!int == 0);
}
