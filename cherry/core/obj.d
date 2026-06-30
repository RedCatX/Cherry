module cherry.core.obj;

import cherry.core.rtti;
import cherry.core.value;
import cherry.core.property;

/**
 * Base class for every object that participates in the Cherry property system.
 *
 * Property values live in a sparse per-instance store keyed by property id, so
 * an object only pays for the properties it actually sets; everything else
 * resolves to the (optionally per-type overridden) default carried by the
 * property's metadata.
 */
class CherryObject
{
   /**
    * Runtime type information for this instance's dynamic type, or null if no
    * RTTI has been created for that type.  Used to resolve per-type metadata.
    */
    @property immutable(RttiClassType) rtti() const
    {
        return rttiForName(typeid(this).name);
    }

   /**
    * Returns the effective value of a property: the locally set value if one
    * exists, otherwise the metadata default.  Read-only properties compute
    * their value through the metadata callback.
    */
    Value getValue(immutable(Property) property) const
    in {
        assert(property !is null);
    }
    do {
        immutable metadata = resolveMetadata(property);

        if (auto readOnlyGet = metadata.onGetReadOnlyValue)
            return readOnlyGet(this);

        if (auto stored = property.id in _values)
            return Value(*stored);

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
        if (property.isReadOnly)
            throw new Exception("Property '" ~ property.name
                ~ "' is read-only and cannot be set directly.");

        setValueCore(property, value);
    }

   /**
    * Removes any locally set value, reverting the property to its default.
    */
    void clearValue(immutable(Property) property)
    in {
        assert(property !is null);
    }
    do {
        _values.remove(property.id);
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
    * Core assignment path.  Bypasses the read-only guard so derived classes
    * can set read-only properties internally (mirrors WPF's key-based set).
    */
    void setValueCore(immutable(Property) property, Value value)
    {
        immutable metadata = resolveMetadata(property);

        // 1. The value must be assignable to the property's declared type.
        if (!property.type.isAssignableFrom(value.typeinfo))
            throw new Exception("A value of type " ~ value.typeinfo.toString()
                ~ " cannot be assigned to property '" ~ property.name
                ~ "' of type " ~ property.type.toString() ~ ".");

        // 2. Let a validator reject the incoming value.
        if (auto validate = property.onValidateValue)
            if (!validate(value))
                throw new Exception("The value assigned to property '"
                    ~ property.name ~ "' failed validation.");

        // 3. Coerce the value into its final form.
        if (auto coerce = metadata.onCoerceValue)
            value = coerce(this, value);

        // 4. Store, and notify only when the effective value actually changed.
        Value oldValue = getValue(property);
        _values[property.id] = value;

        if (oldValue != value)
            metadata.raisePropertyChanged(this, oldValue, value);
    }

private:
    immutable(PropertyMetadata) resolveMetadata(immutable(Property) property) const
    {
        auto dynamicType = rtti;
        if (dynamicType !is null)
            return property.getMetadata(dynamicType);

        return property.defaultMetadata;
    }

    Value[uint] _values;
}
