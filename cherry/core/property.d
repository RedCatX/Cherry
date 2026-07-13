module cherry.core.property;

import cherry.core.rtti;
import cherry.core.value;
import cherry.core.multicast;
import cherry.core.obj;

alias PropertyChangedCallback = void function(const(Object), const(Value), const(Value));
alias PropertyChangedCallbackList = Multicast!PropertyChangedCallback;
alias CoerceValueCallback = Value function(Object, Value);
alias ValidateValueCallback = bool function(const(Value));
alias GetReadOnlyValueCallback = Value function(const(Object));

struct PropertyMetadata
{
    @property bool affectsMeasure() pure const nothrow
    {
        return getFlag(Flags.affectsMeasure);
    }

    @property void affectsMeasure(bool value) pure nothrow
    {
        setFlag(Flags.affectsMeasure, value);
    }

    @property bool affectsArrange() pure const nothrow
    {
        return getFlag(Flags.affectsArrange);
    }

    @property void affectsArrange(bool value) pure nothrow
    {
        setFlag(Flags.affectsArrange, value);
    }

    @property bool affectsParentMeasure() pure const nothrow
    {
        return getFlag(Flags.affectsParentMeasure);
    }

    @property void affectsParentMeasure(bool value) pure nothrow
    {
        setFlag(Flags.affectsParentMeasure, value);
    }

    @property bool affectsParentArrange() pure const nothrow
    {
        return getFlag(Flags.affectsParentArrange);
    }

    @property void affectsParentArrange(bool value) pure nothrow
    {
        setFlag(Flags.affectsParentArrange, value);
    }

    @property bool affectsRender() pure const nothrow
    {
        return getFlag(Flags.affectsRender);
    }

    @property void affectsRender(bool value) pure nothrow
    {
        setFlag(Flags.affectsRender, value);
    }

    @property bool isAnimationProhibited() pure const nothrow
    {
        return getFlag(Flags.isAnimationProhibited);
    }

    @property void isAnimationProhibited(bool value) pure nothrow
    {
        setFlag(Flags.isAnimationProhibited, value);
    }

    @property bool inherits() pure const nothrow
    {
        return getFlag(Flags.inherits);
    }

    @property void inherits(bool value) pure nothrow
    {
        setFlag(Flags.inherits, value);
    }

    @property bool journaled() pure const nothrow
    {
        return getFlag(Flags.journaled);
    }

    @property void journaled(bool value) pure nothrow
    {
        setFlag(Flags.journaled, value);
    }

    @property bool notBindable() pure const nothrow
    {
        return getFlag(Flags.notBindable);
    }

    @property void notBindable(bool value) pure nothrow
    {
        setFlag(Flags.notBindable, value);
    }

    @property bool subPropertiesDoNotAffectRender() pure const nothrow
    {
        return getFlag(Flags.subPropertiesDoNotAffectRender);
    }

    @property void subPropertiesDoNotAffectRender(bool value) pure nothrow
    {
        setFlag(Flags.subPropertiesDoNotAffectRender, value);
    }

    @property const(Value) defaultValue() const
    {
        return _defaultValue;
    }

    @property void defaultValue(const(Value) v)
    {
        _defaultValue = v;
        setFlag(Flags.defaultValueModified, true);
    }

    @property GetReadOnlyValueCallback onGetReadOnlyValue() pure const nothrow
    {
        return _onGetReadOnlyValue;
    }

    @property void onGetReadOnlyValue(GetReadOnlyValueCallback callback) pure nothrow
    {
        _onGetReadOnlyValue = callback;
    }

    @property ref PropertyChangedCallbackList onPropertyChanged()
    {
        return _onPropertyChanged; 
    }

   /**
    * Invokes the registered property-changed handlers in order.  Callable on
    * an immutable metadata instance, as returned by Property.getMetadata.
    */
    void raisePropertyChanged(const(Object) obj, const(Value) oldValue, const(Value) newValue) const
    {
        if (!_onPropertyChanged.empty)
            _onPropertyChanged(obj, oldValue, newValue);
    }

    @property CoerceValueCallback onCoerceValue() pure const nothrow
    {
        return _onCoerceValue;
    }

    @property void onCoerceValue(CoerceValueCallback callback) pure nothrow
    {
        _onCoerceValue = callback;
    }

protected:
    @property bool defaultValueWasSet() pure const nothrow
    {
        return getFlag(Flags.defaultValueModified);
    }

    @property bool changed() pure const nothrow
    {
        return _flags != 0 
			|| _onGetReadOnlyValue != null
			|| _onCoerceValue != null
			|| !_onPropertyChanged.empty;
    }

private:
    enum Flags : ushort
    {
        // Property affects measurement
        affectsMeasure                 = 0x001,
        // Property affects arragement
        affectsArrange                 = 0x002,
        // Property affects parent's measurement
        affectsParentMeasure           = 0x004,
        // Property affects parent's arrangement
        affectsParentArrange           = 0x008,
        // Property affects rendering
        affectsRender                  = 0x010,
        // Property inherits to children
        isAnimationProhibited          = 0x020,
        inherits                       = 0x040,
        journaled                      = 0x080,
        // Property does not support data binding
        notBindable                    = 0x100,
        // Property's subproperties do not affect rendering.
        // For instance, a property X may have a subproperty Y.
        // Changing X.Y does not require rendering to be updated.
        subPropertiesDoNotAffectRender = 0x200,
        isReadOnlyProperty             = 0x400,
        defaultValueModified           = 0x800,
        userDefinedFlagsMask           = 0x3FF
    }

    bool getFlag(Flags flag) pure const nothrow
    {
        return (_flags & flag) != 0;
    }

    void setFlag(Flags flag, bool value) pure nothrow
    {
        if (value)
        {
            _flags |= flag;
        }
        else
        {
            _flags &= (~flag);
        }
    }

    void merge(immutable(PropertyMetadata) baseMetadata)
    {
        // Take source default if this default was never set
        if (!getFlag(Flags.defaultValueModified))
            _defaultValue = baseMetadata._defaultValue;
  
        if (!baseMetadata._onPropertyChanged.empty)
        {
            // Build the handler list such that handlers added
            // via OverrideMetadata are called last (base invocation first)
            PropertyChangedCallbackList handlers;
            handlers ~= baseMetadata._onPropertyChanged;
            handlers ~= _onPropertyChanged;
            _onPropertyChanged = handlers;
        }

        if (_onCoerceValue == null)
            _onCoerceValue = baseMetadata._onCoerceValue;

        _flags |= (baseMetadata._flags & Flags.userDefinedFlagsMask);
    }

    Value                       _defaultValue;
    GetReadOnlyValueCallback    _onGetReadOnlyValue;
    PropertyChangedCallbackList _onPropertyChanged;
    CoerceValueCallback         _onCoerceValue;
    ushort                      _flags;
}

unittest
{
    PropertyMetadata meta;
    // Flags test
    assert(!meta.affectsMeasure);
    meta.affectsMeasure = true;
    assert(meta.affectsMeasure);
    assert(!meta.affectsArrange);
    meta.affectsArrange = true;
    assert(meta.affectsArrange);
    assert(!meta.affectsParentMeasure);
    meta.affectsParentMeasure = true;
    assert(meta.affectsParentMeasure);
    assert(!meta.affectsParentArrange);
    meta.affectsParentArrange = true;
    assert(meta.affectsParentArrange);
    assert(!meta.affectsRender);
    meta.affectsRender = true;
    assert(meta.affectsRender);
    assert(!meta.isAnimationProhibited);
    meta.isAnimationProhibited = true;
    assert(meta.isAnimationProhibited);
    assert(!meta.inherits);
    meta.inherits = true;
    assert(meta.inherits);
    assert(!meta.journaled);
    meta.journaled = true;
    assert(meta.journaled);
    assert(!meta.notBindable);
    meta.notBindable = true;
    assert(meta.notBindable);
    assert(!meta.subPropertiesDoNotAffectRender);
    meta.subPropertiesDoNotAffectRender = true;
    assert(meta.subPropertiesDoNotAffectRender);
    // Callbacks test
    static void fun1(const(Object), const(Value), const(Value)) {}
    static void fun2(const(Object), const(Value), const(Value)) {}
    assert(meta.onPropertyChanged.empty);
    meta.onPropertyChanged ~= &fun1;
    meta.onPropertyChanged ~= &fun2;
    assert(!meta.onPropertyChanged.empty);
    assert(meta.onPropertyChanged.delegates.length == 2);
    assert(meta.onPropertyChanged.delegates[0] == &fun1);
    assert(meta.onPropertyChanged.delegates[1] == &fun2);
    
    // Merge test
    meta._flags = 0;
    assert(meta.defaultValue.empty);
    assert(!meta.defaultValueWasSet);
    meta.defaultValue = Value(10);
    assert(meta.defaultValueWasSet);
    assert(!meta.defaultValue.empty);
    assert(meta.defaultValue.get!int == 10);
    meta.affectsMeasure = true;
    meta.affectsParentMeasure = true;
    meta.isAnimationProhibited = true;
    meta.inherits = true;
    assert(meta.affectsMeasure);
    assert(meta.affectsParentMeasure);
    assert(meta.isAnimationProhibited);
    assert(meta.inherits);
    assert(!meta.affectsArrange);
    assert(!meta.affectsParentArrange);
    assert(!meta.affectsRender);

    PropertyMetadata baseMetadata;
    baseMetadata.affectsArrange = true;
    baseMetadata.affectsParentArrange = true;
    baseMetadata.affectsRender = true;
    static void fun3(const(Object), const(Value), const(Value)) {}
    static Value fun4(Object, Value v) { return v; }
    baseMetadata.onPropertyChanged = &fun3;
    assert(!baseMetadata.onPropertyChanged.empty);
    assert(baseMetadata.onPropertyChanged.delegates.length == 1);
    assert(baseMetadata.onPropertyChanged.delegates[0] == &fun3);
    assert(baseMetadata.onCoerceValue == null);
    baseMetadata.onCoerceValue = &fun4;
    assert(baseMetadata.onCoerceValue == &fun4);
    meta.merge(cast(immutable PropertyMetadata) baseMetadata);
    assert(!meta.defaultValue.empty);
    assert(meta.defaultValue.get!int == 10);
    assert(meta.affectsMeasure);
    assert(meta.affectsParentMeasure);
    assert(meta.isAnimationProhibited);
    assert(meta.inherits);
    assert(meta.affectsArrange);
    assert(meta.affectsParentArrange);
    assert(meta.affectsRender);
    assert(!meta.onPropertyChanged.empty);
    assert(meta.onPropertyChanged.delegates.length == 3);
    assert(meta.onPropertyChanged.delegates[0] == &fun3);
    assert(meta.onPropertyChanged.delegates[1] == &fun1);
    assert(meta.onPropertyChanged.delegates[2] == &fun2);
    assert(meta.onCoerceValue == &fun4);
}

/**
 * Grants the right to set a read-only property.
 *
 * A key is returned only by Property.registerReadOnly and
 * Property.registerAttachedReadOnly; the private constructor makes it
 * unforgeable outside this module.  The registering code keeps the key
 * private and publishes key.property for readers, so possession of the key
 * is the write permission (the analogue of WPF's DependencyPropertyKey).
 */
final immutable class ReadOnlyPropertyKey
{
   /**
    * The read-only property this key can write.
    */
    @property immutable(Property) property() pure const nothrow
    {
        return _property;
    }

private:
    this(immutable(Property) property)
    {
        _property = property;
    }

    Property _property;
}

final immutable class Property
{
   /**
    * Register a new Cherry Property
    *
    * Params:
    *     name = Name of property
    *     type = Type of the property
    *     ownerType = Type that is registering the property
    *     metadata = Metadata of the property
    *     validateValueCallback = Provides additional value validation outside automatic type validation
    *
    * Returns:
    *     A new registred immutable Property object
    */
    static immutable(Property) register(string name, 
                                        immutable(Rtti) type,
                                        immutable(RttiClassType) ownerType,
                                        PropertyMetadata metadata = PropertyMetadata.init,
                                        ValidateValueCallback validateValueCallback = null)
    in {
        assert(name != null && name != "");
        assert(type !is null);
        assert(ownerType !is null);
    }
    body {
        PropertyMetadata defaultMetadata;
        if (metadata.changed && metadata.defaultValueWasSet)
		{
            defaultMetadata.defaultValue = metadata.defaultValue;
		}
        else
		{
            defaultMetadata = makeDefaultMetadata(type, validateValueCallback, ownerType.name ~ '.' ~ name);
		}

        immutable(Property) property = new immutable(Property)(name, type, ownerType, defaultMetadata, validateValueCallback);

        if (metadata.changed)
        {
            property.overrideMetadata(ownerType, metadata);
        }

        return property;
    }

    /**
    * Register a new read-only property.
    * Calling this version restricts the property such that it can only  
    * be set via the CherryObject.setValue overload taking the returned key.
    *
    * Params:
    *     name = Name of property
    *     type = Type of the property
    *     ownerType = Type that is registering the property
    *     metadata = Type metadata of the property
    *     validateValueCallback = Provides additional value validation outside automatic type validation
    *
    * Returns:
    *     A new registred immutable Property object
    */
    static immutable(ReadOnlyPropertyKey) registerReadOnly(string name, 
												immutable(Rtti) type,
												immutable(RttiClassType) ownerType,                                                      
                                                PropertyMetadata metadata = PropertyMetadata.init,
                                                ValidateValueCallback validateValueCallback = null)
    {
        auto property = register(name, type, ownerType, metadata, validateValueCallback);
        PropertyRegistry.get().setFlag(property._id, Flags.isReadOnlyProperty, true);
        return new immutable(ReadOnlyPropertyKey)(property);
    }

   /**
    * Register a new attached read-only property.
    * Calling this version restricts the property such that it can only  
    * be set via the CherryObject.setValue overload taking the returned key.
    *
    * Params:
    *     name = Name of property
    *     type = Type of the property
    *     ownerType = Type that is registering the property
    *     metadata = Type metadata of the property
    *     validateValueCallback = Provides additional value validation outside automatic type validation
    *
    * Returns:
    *     The registration key; the property itself is exposed via key.property
    */
    static immutable(ReadOnlyPropertyKey) registerAttachedReadOnly(string name, 
														immutable(Rtti) type,
														immutable(RttiClassType) ownerType, 
                                                        PropertyMetadata defaultMetadata = PropertyMetadata.init,
                                                        ValidateValueCallback validateValueCallback = null)
    in {
        assert(name != null && name != "");
        assert(type !is null);
        assert(ownerType !is null);
    }
    body {
        if (!defaultMetadata.changed)
		{
            defaultMetadata = makeDefaultMetadata(type, validateValueCallback, ownerType.name ~ '.' ~ name);
		}

        immutable(Property) property = new immutable(Property)(name, type, ownerType, defaultMetadata, validateValueCallback);
        PropertyRegistry.get().setFlag(property._id, Flags.isAttachedProperty, true);
        PropertyRegistry.get().setFlag(property._id, Flags.isReadOnlyProperty, true);

        return new immutable(ReadOnlyPropertyKey)(property);
    }

   /**
    * Register a new attached Cherry Property
    *
    * Params:
    *     name = Name of property
    *     type = Type of the property
    *     ownerType = Type that is registering the property
    *     defaultMetadata = Default metadata of the property
    *     validateValueCallback = Provides additional value validation outside automatic type validation
    *
    * Returns:
    *     A new registred immutable Property object
    */
    static immutable(Property) registerAttached(string name, 
                                                immutable(Rtti) type,
												immutable(RttiClassType) ownerType,
                                                PropertyMetadata defaultMetadata = PropertyMetadata.init,
                                                ValidateValueCallback validateValueCallback = null)
    in {
        assert(name != null && name != "");
        assert(type !is null);
        assert(ownerType !is null);
    }
    body {
        auto property = new immutable(Property)(name, type, ownerType, defaultMetadata, validateValueCallback);
        PropertyRegistry.get().setFlag(property._id, Flags.isAttachedProperty, true);
        return property;
    }

    /**
    * Get the metadata of this property for a given owner type. 
	* If no metadata was registered for the given owner type, 
	* the metadata of the closest base type is returned. 
	* If no metadata was registered for any base type, the default metadata is returned.
    * 
    * Params:
    *	 ownerType = Type for which to get the metadata
    *
    * Returns:
	*     Metadata of this property for the given owner type
    */
    immutable(PropertyMetadata) getMetadata(immutable(RttiClassType) ownerType) immutable
    {
        return PropertyRegistry.get().getMetadata(_id, ownerType);
    }

   /**
    * Override the metadata of this property for a given owner type.
    * The supplied metadata will be merged with the type's base metadata.
    *
    * Params:
    *  ownerType = Type for which to override the metadata
    *  metadata = Metadata to override. This will be merged with the base metadata of the type.
    */
    void overrideMetadata(immutable(RttiClassType) forType, PropertyMetadata typeMetadata) const
    in {
        assert(forType !is null);
    }
    body {
		if ( !getRtti!CherryObject().isAssignableFrom(forType) )
		{
		    throw new Exception(buildFullName(forType) ~ ": only types derived from CherryObject can override property metadata.");
		}

        if ( typeMetadata.defaultValueWasSet )
		{
		    validateDefaultValue(typeMetadata.defaultValue, _type, _onValidateValue, buildFullName(_ownerType));
		}

        // Attached properties may be customized for any host type;
        // only regular properties are restricted to the owner's hierarchy.
        if ( !isAttached && !_ownerType.isAssignableFrom(forType) )
		{
            throw new Exception(buildFullName(_ownerType) ~ ": overriding metadata does not match base metadata type");
		}

        PropertyRegistry.get().overrideMetadata(this, forType, typeMetadata);
    }

    @property string name() pure const nothrow
    {
        return _name;
    }

    @property immutable(Rtti) type() pure const nothrow
    {
        return _type;
    }

    @property immutable(RttiClassType) ownerType() pure const nothrow
    {
        return _ownerType;
    }

    @property immutable(PropertyMetadata) defaultMetadata() pure const nothrow
    {
        return _defaultMetadata;
    }

    @property ValidateValueCallback onValidateValue() pure const nothrow
    {
        return _onValidateValue;
    }

    @property uint id() pure const nothrow
	{
        return _id;
	}

    @property bool isAttached() const
    {
        return PropertyRegistry.get().getFlag(_id, Flags.isAttachedProperty);
    }

    @property bool isReadOnly() const
	{
        return PropertyRegistry.get().getFlag(_id, Flags.isReadOnlyProperty);
	}

protected:
    string buildFullName(immutable(RttiClassType) ownerType) const
    {
        return ownerType.name ~ '.' ~ _name;
    }

    enum Flags : ushort
    {
        isAttachedProperty = 0x0001,
        isReadOnlyProperty = 0x0002,
        isPotentiallyInherited = 0x0004,
		isDefaultValueChanged = 0x0008
    }

private:
	this(string name, 
         immutable(Rtti) type, 
         immutable(RttiClassType) ownerType,
         PropertyMetadata defaultMetadata,
         ValidateValueCallback validateValueCallback)
    {
        _name = name;
        _type = type;
        _ownerType = ownerType;

        string fullName = buildFullName(ownerType);

        // Validate a user-supplied default before the property is added to
        // the registry, so a failed registration stays atomic and the error
        // surfaces at the registration site, not at first use.
        if ( defaultMetadata.defaultValueWasSet() )
        {
            validateDefaultValue(defaultMetadata.defaultValue, type, validateValueCallback, fullName);
        }

        if ( !defaultMetadata.defaultValueWasSet() )
		{
            Value defaultValue = makeDefaultValue(type);
			validateDefaultValue(defaultValue, type, validateValueCallback, fullName);
			defaultMetadata.defaultValue = defaultValue;
		}

        _defaultMetadata = cast(immutable PropertyMetadata) defaultMetadata;
        _onValidateValue = validateValueCallback;

        _id = PropertyRegistry.get().add(this, fullName);
    }

    static Value makeDefaultValue(immutable(Rtti) propertyType)
    {
        if (propertyType.type == Rtti.Type.Class ||
			propertyType.type == Rtti.Type.Pointer)
		{
            return Value(propertyType, null);
		}

        if (propertyType.initPtr == null)
		{
            return Value(propertyType, new ubyte[](propertyType.size).ptr);
		}

        return Value(propertyType, propertyType.initPtr[0..propertyType.size].dup.ptr);
    }

    static PropertyMetadata makeDefaultMetadata(immutable(Rtti) propertyType,
	                                            ValidateValueCallback validateValueCallback,
	                                            string propertyName)
    {
        Value defaultValue = makeDefaultValue(propertyType);
		PropertyMetadata defaultMetadata;

		// If a validator is passed in, see if the default value makes sense.
		if ( validateValueCallback != null &&
			 !validateValueCallback(defaultValue) )
		{
			throw new Exception("Failed to create default value for " ~ propertyName ~ " property: validation failed.");
		}

        defaultMetadata.defaultValue = defaultValue;

        return defaultMetadata;
    }

    static void validateDefaultValue(const(Value) defaultValue, 
									 immutable(Rtti) propertyType,
									 ValidateValueCallback validateValueCallback,
									 string propertyName)
	{
        if ( !propertyType.isAssignableFrom(defaultValue.typeinfo) )
		{
            throw new Exception("Failed to assign default value for " ~ propertyName ~ " property: types mismatch.");
		}

        if ( validateValueCallback != null &&
			 !validateValueCallback(defaultValue) )
		{
			throw new Exception("Invalid default value for " ~ propertyName ~ " property.");
		}
	}

    void validateParameters(string name, immutable(Rtti) type, immutable(RttiClassType) ownerType)
	{
	    import std.ascii : isAlpha, isDigit;

	    // Check name
	    assert(isAlpha(name[0]) || name[0] == '_', "Property name must start with 'a'..'z', 'A'..'Z', or '_'");
	    for (size_t i = 1; i < name.length - 1; i++)
	        assert(isAlpha(name[i]) || isDigit(name[i]) || name[i] == '_', "Property name must contain only 'a'..'z', 'A'..'Z', '0'..'9', and '_' symbols");

	    // Check type
        
	}

    uint                  _id;
    string                _name;
    Rtti                  _type;
    RttiClassType         _ownerType;
    PropertyMetadata      _defaultMetadata;
    ValidateValueCallback _onValidateValue;
}

final class PropertyRegistry
{
    static PropertyRegistry get()
	{
        if ( !_instantiated )
		{
		    synchronized ( PropertyRegistry.classinfo )
			{
			    if ( !_instance )
                {
                    _instance = new PropertyRegistry;
                }

                _instantiated = true;
            }
        }

        return _instance;
	}

protected:
    bool getFlag(uint propertyId, Property.Flags flag) const 
	{
        return (_properties[propertyId].flags & flag) != 0;
	}

    void setFlag(uint propertyId, Property.Flags flag, bool value)
	{
        synchronized ( PropertyRegistry.classinfo )
		{
            if (value)
            {
                _properties[propertyId].flags |= flag;
            }
            else
            {
                _properties[propertyId].flags &= ~flag;
            }
		}
	}

    uint add(immutable(Property) prop, string fullName)
	{
        uint id;

        synchronized ( PropertyRegistry.classinfo )
		{
            id = cast(uint)(_properties.length);

            if ( id <= uint.max )
		    {
			    if (fullName in _propertyByName)
				    throw new Exception(fullName ~ ": a property with the same name is already registered for this type.");

			    _properties ~= PropertyContainer( property: prop );
			    _propertyByName[fullName] = id;
		    }
		    else
			    throw new Exception(fullName ~ ": too many properties registered.");
		}

        return id;
	}

    immutable(PropertyMetadata) getMetadata(uint propertyId, immutable(RttiClassType) ownerType) const
	{
        immutable(PropertyMetadata) getRecursive(immutable(RttiClassType) ownerType)
		{
            auto m = (ownerType.name in _properties[propertyId].metadataMap);

            if (m !is null)
		    {
                return *cast(immutable(PropertyMetadata)*) m;
		    }
            else if (ownerType.baseClass !is null)
		    {
                return getRecursive(ownerType.baseClass);
		    }

            return _properties[propertyId].property.defaultMetadata;
		}

        synchronized ( PropertyRegistry.classinfo )
		{
            return getRecursive(ownerType);
		}
	}

    void overrideMetadata(immutable(Property) property, immutable(RttiClassType) forType, PropertyMetadata typeMetadata)
	{
        synchronized ( PropertyRegistry.classinfo )
		{
            if (forType.name in _properties[property.id].metadataMap)
			    throw new Exception(property.buildFullName(forType) ~ ": metadata for this type is already overridden.");

		    typeMetadata.merge(getMetadata(property.id, forType.baseClass));
        
		    _properties[property.id].metadataMap[forType.name] = typeMetadata;
		}

		if (typeMetadata.inherits)
		{
			setFlag(property.id, Property.Flags.isPotentiallyInherited, true);
		}

		if ( typeMetadata.defaultValueWasSet && typeMetadata.defaultValue != property.defaultMetadata.defaultValue )
		{
			setFlag(property.id, Property.Flags.isDefaultValueChanged, true);
		}
	}

private:
    this()
	{
	}

    struct PropertyContainer
    {
        immutable(Property) property;
        PropertyMetadata[string] metadataMap;
        ushort flags;
    }

    __gshared PropertyRegistry _instance;
    static bool                _instantiated;
    ulong[string]              _propertyByName;
    PropertyContainer[]        _properties;
}

unittest 
{
    class Test : CherryObject
	{
        shared static this()
		{
            PropertyMetadata testPropertyMetadata;
            testPropertyMetadata.affectsMeasure = true;

            testProperty = Property.register("test", getRtti!int(), getRtti!Test());
		}

        static immutable(Property) testProperty;
	}

    assert(Test.testProperty !is null);
    
}

unittest
{
    import std.exception : assertThrown;

    static class AttachOwner : CherryObject
    {
    }

    static class ForeignHost : CherryObject
    {
    }

    // A type-mismatched user-supplied default is rejected at registration
    // time, on every registration path.
    PropertyMetadata bad;
    bad.defaultValue = Value("oops");
    assertThrown(Property.register("BadDefault", getRtti!int(), getRtti!AttachOwner(), bad));
    assertThrown(Property.registerAttached("BadDefault", getRtti!int(), getRtti!AttachOwner(), bad));

    // A failed registration does not reserve the property name.
    PropertyMetadata good;
    good.defaultValue = Value(5);
    auto recovered = Property.register("BadDefault", getRtti!int(), getRtti!AttachOwner(), good);
    assert(recovered.defaultMetadata.defaultValue.get!int == 5);

    // An attached property's metadata can be overridden for a host type
    // unrelated to the owner; a regular property still cannot.
    PropertyMetadata baseMeta;
    baseMeta.defaultValue = Value(1);
    auto attached = Property.registerAttached("ForeignOverride", getRtti!int(), getRtti!AttachOwner(), baseMeta);
    auto regular  = Property.register("ForeignOverride2", getRtti!int(), getRtti!AttachOwner(), baseMeta);

    PropertyMetadata hostMeta;
    hostMeta.defaultValue = Value(42);
    attached.overrideMetadata(getRtti!ForeignHost(), hostMeta);
    assert(attached.getMetadata(getRtti!ForeignHost()).defaultValue.get!int == 42);
    assert(attached.getMetadata(getRtti!AttachOwner()).defaultValue.get!int == 1);

    PropertyMetadata hostMeta2;
    hostMeta2.defaultValue = Value(42);
    assertThrown(regular.overrideMetadata(getRtti!ForeignHost(), hostMeta2));
}

unittest
{
    import std.exception : assertThrown;

    static class Secured : CherryObject
    {
    }

    PropertyMetadata meta;
    meta.defaultValue = Value(1);

    auto key = Property.registerReadOnly("Locked", getRtti!int(), getRtti!Secured(), meta);
    auto lockedProperty = key.property;
    assert(lockedProperty.isReadOnly);
    assert(!lockedProperty.isAttached);

    auto obj = new Secured;

    // The public setter rejects a read-only property...
    assertThrown(obj.setValue(lockedProperty, Value(5)));
    assert(obj.getValue(lockedProperty).get!int == 1);

    // ...while possession of the key is the write permission.
    obj.setValue(key, Value(5));
    assert(obj.getValue(lockedProperty).get!int == 5);

    // Attached read-only: the owner's key sets the value on foreign hosts.
    auto attachedKey = Property.registerAttachedReadOnly("LockedAttached", getRtti!int(), getRtti!Secured(), meta);
    assert(attachedKey.property.isReadOnly);
    assert(attachedKey.property.isAttached);

    auto host = new CherryObject;
    assertThrown(host.setValue(attachedKey.property, Value(7)));
    host.setValue(attachedKey, Value(7));
    assert(host.getValue(attachedKey.property).get!int == 7);
}
