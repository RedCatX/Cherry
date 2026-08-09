module cherry.core.obj;

import cherry.core.rtti;
import cherry.core.value;
import cherry.core.property;
import cherry.core.threading;

/**
 * Base class for every object that participates in the Cherry property system.
 *
 * Property values live in a sparse per-instance store keyed by property id, so
 * an object only pays for the properties it actually sets; everything else
 * resolves to the (optionally per-type overridden) default carried by the
 * property's metadata.
 *
 * Deriving from DispatcherObject binds every instance to the dispatcher of
 * the thread that created it, which is what makes the affinity checks below
 * meaningful.
 */
class CherryObject : DispatcherObject
{
   /**
    * Runtime type information for this instance: its own dynamic type if that
    * type has any, otherwise the nearest ancestor that does, and null when no
    * class in the chain has RTTI at all.  Used to resolve per-type metadata.
    *
    * The walk up matters.  RTTI exists only for types that asked for it, and
    * in practice that means types that registered a property; a class that
    * merely uses what it inherits registers none.  Looking up its own name
    * alone would find nothing, metadata would fall back to the property's
    * bare default, and every per-type override the base class registered --
    * change callbacks included -- would be silently skipped.
    */
    @property immutable(RttiClassType) rtti() const
    {
        for (TypeInfo_Class type = typeid(this); type !is null; type = type.base)
            if (auto found = rttiForName(type.name))
                return found;

        return null;
    }

   /**
    * Returns the effective value of a property: the locally set value if one
    * exists; otherwise, for properties whose metadata sets `inherits`, the
    * nearest inherited value down the inheritance chain; otherwise the
    * metadata default.  Read-only properties compute their value through
    * the metadata callback.
    */
    Value getValue(immutable(Property) property) const
    in {
        assert(property !is null);
    }
    do {
        verifyAccess();

        immutable metadata = resolveMetadata(property);

        if (auto readOnlyGet = metadata.onGetReadOnlyValue)
            return readOnlyGet(this);

        if (auto stored = property.id in _values)
            return Value(*stored);

        if (metadata.inherits)
        {
            Value inherited;
            auto ancestor = inheritanceParent;
            if (ancestor !is null && ancestor.findInheritedValue(property, inherited))
                return inherited;
        }

        return Value(metadata.defaultValue);
    }

   /**
    * Assigns a new value to a property.  Throws if the property is read-only,
    * if the value is not assignable to the property's type, or if a validator
    * rejects it.  Fires the change handlers when the effective value changes.
    */
    void setValue(immutable(Property) property, Value value)
    in {
        assert(property !is null);
    }
    do {
        verifyAccess();

        if (property.isReadOnly)
            throw new Exception("Property '" ~ property.name
                ~ "' is read-only and cannot be set directly.");

        setValueCore(property, value);
    }

   /**
    * Assigns a new value to a read-only property.  Possession of the
    * registration key is the write permission: keys cannot be created
    * outside the property module, so only code the owner shared the key
    * with can take this path.
    */
    void setValue(immutable(ReadOnlyPropertyKey) key, Value value)
    in {
        assert(key !is null);
    }
    do {
        verifyAccess();

        setValueCore(key.property, value);
    }

   /**
    * Removes any locally set value, reverting the property to its default --
    * or, for a property that inherits, to whatever the chain supplies.
    *
    * Reported like any other change, because it is one: the effective value is
    * read before and after, and the handlers run when the two differ.  Nothing
    * distinguishes "reverted to 100" from "assigned 100" to a handler, and
    * nothing should: what a handler acts on is the value, not the route it
    * arrived by.
    */
    void clearValue(immutable(Property) property)
    in {
        assert(property !is null);
    }
    do {
        verifyAccess();

        if ((property.id in _values) is null)
            return;

        immutable metadata = resolveMetadata(property);

        // Read through getValue rather than the table, so an inherited value or
        // a computed read-only one is what gets compared -- the removal only
        // uncovers whatever was underneath.
        Value oldValue = getValue(property);
        _values.remove(property.id);
        Value newValue = getValue(property);

        if (oldValue != newValue)
            notifyChanged(property, metadata, oldValue, newValue);
    }

   /**
    * Whether a local (non-default) value is currently set for the property.
    */
    bool hasLocalValue(immutable(Property) property) const
    {
        return (property.id in _values) !is null;
    }

protected:
   /**
    * The object that supplies inherited property values, or null when this
    * object has no inheritance context.  A layer with a tree overrides this to
    * return the node above; plain property-bearing objects do not inherit.
    *
    * `const` and not `inout`: the only two readers are getValue and
    * findInheritedValue, both `const` and neither writing through the result,
    * so a mutable answer would be a qualifier every override has to carry for
    * nobody's benefit.  Unattributed for the same reason -- a layer answering
    * this from a lookup rather than from a field cannot honour `pure nothrow
    * @nogc`, and neither reader needs it.
    */
    @property const(CherryObject) inheritanceParent() const
    {
        return null;
    }

   /**
    * Called when a property's effective value has changed, before the
    * metadata's own change handlers run.
    *
    * The seam a layer above hooks its bookkeeping onto without the property
    * system learning what that bookkeeping is: Element reads the layout flags
    * here, and cherry.core stays free of anything in cherry.ui.
    *
    * It runs first so the framework has settled its own invariants -- the
    * element marked dirty, the layout pass queued -- before any handler gets
    * to look at the object.  A handler that reads a size is then reading one
    * the framework already agrees with.
    *
    * The resolved metadata is handed over rather than looked up again:
    * resolving walks the class hierarchy under the registry lock, and this is
    * on the path of every property write.
    */
    void onPropertyChanged(immutable(Property) property,
                           ref immutable(PropertyMetadata) metadata,
                           const(Value) oldValue,
                           const(Value) newValue)
    {
    }

private:
   /*
    * The type rule in one place.  An empty Value fits any property: it is not
    * a value of the wrong type but the absence of one, and a property may be
    * left without a value whatever its type.
    */
    static bool fits(immutable(Property) property, ref const Value value)
    {
        return value.empty || property.type.isAssignableFrom(value.typeinfo);
    }

   /*
    * Core assignment path: type-check, validate, coerce, store, notify.
    * Bypasses the read-only guard; external code reaches it only through
    * the ReadOnlyPropertyKey overload of setValue.
    */
    void setValueCore(immutable(Property) property, Value value)
    {
        immutable metadata = resolveMetadata(property);

        // 1. The value must be assignable to the property's declared type.
        if (!fits(property, value))
            throw new Exception("A value of type " ~ value.typeinfo.toString()
                ~ " cannot be assigned to property '" ~ property.name
                ~ "' of type " ~ property.type.toString() ~ ".");

        // 2. Let a validator reject the incoming value.
        if (auto validate = property.onValidateValue)
            if (!validate(value))
                throw new Exception("The value assigned to property '"
                    ~ property.name ~ "' failed validation.");

        // 3. Coerce the value into its final form, and hold it to the same
        //    rule as the caller.  A coerce callback is ordinary code and can
        //    return the wrong type; stored unchecked, that surfaces as a
        //    failure at the next read of the property, by which point nothing
        //    connects it to the coercion that caused it.
        if (auto coerce = metadata.onCoerceValue)
        {
            value = coerce(this, value);

            if (!fits(property, value))
                throw new Exception("The coerce callback for property '"
                    ~ property.name ~ "' returned a value of type "
                    ~ value.typeinfo.toString() ~ ", which cannot be assigned to "
                    ~ property.type.toString() ~ ".");
        }

        // 4. Store, and notify only when the effective value actually changed.
        Value oldValue = getValue(property);
        _values[property.id] = value;

        if (oldValue != value)
            notifyChanged(property, metadata, oldValue, value);
    }

   /*
    * The one place a property change is announced, shared by assignment and by
    * clearValue so the two cannot drift apart.
    */
    void notifyChanged(immutable(Property) property,
                       ref immutable(PropertyMetadata) metadata,
                       Value oldValue,
                       Value newValue)
    {
        onPropertyChanged(property, metadata, oldValue, newValue);
        metadata.raisePropertyChanged(this, oldValue, newValue);
    }

private:
   /*
    * Walks the inheritance chain starting at this object, looking for the
    * nearest locally set value of the property.  The caller has already
    * checked its own local store, so this is invoked on the parent.
    * Recursive because a const class reference cannot be rebound in a loop.
    */
    bool findInheritedValue(immutable(Property) property, out Value result) const
    {
        if (auto stored = property.id in _values)
        {
            result = Value(*stored);
            return true;
        }

        auto ancestor = inheritanceParent;
        return ancestor !is null && ancestor.findInheritedValue(property, result);
    }

    immutable(PropertyMetadata) resolveMetadata(immutable(Property) property) const
    {
        auto dynamicType = rtti;
        if (dynamicType !is null)
            return property.getMetadata(dynamicType);

        return property.defaultMetadata;
    }

    Value[uint] _values;
}


