module cherry.core.rtti;

import std.traits;

import cherry.core.multicast : event;

class Rtti
{
    enum Type
    {
        Null,
        Void,
        Integer,
        Float,
        Enum,
        StaticArray,
        DynamicArray,
        AssociativeArray,
        Class,
        Struct,
        Function,
        Pointer
    }

    enum Qualifier : ubyte
    {
        None             = 0,
        Immutable        = 0b00000001,
        Const            = 0b00000010,
        Inout            = 0b00000100,
        Shared           = 0b00001000,
        ConstShared      = Const | Shared,
        ConstInout       = Const | Inout,
        InoutShared      = Inout | Shared,
        ConstInoutShared = Const | Inout | Shared
    }

    /**
    * Name property
    * Returns: name of the type represented in this Rtti.
    */
    @property string name() pure const nothrow 
    {
        return _name; 
    }

    /**
    * Size property
    * Returns: value of .sizeof called on the type represented in this Rtti.
    */
    @property size_t size() pure const nothrow 
    {
        return _size;
    }

    /**
    * InitPtr property
    * Returns: the pointer to the type info object returned by typeid(T).init.ptr, 
	*          where T is the type represented in this Rtti. This is used for generic 
	*          type parameters to determine whether two generic type parameters are the same.
    */
    @property const(void)* initPtr() pure const nothrow
    {
        return _initPtr;
    }

    /**
    * Type property
    * Returns: generic kind of the type represented in this Rtti.
    */
    @property Type type() pure const nothrow
    {
        return _type;
    }

   /**
    * Qualifiers property
    * Returns: Type qualifiers
    */
    @property Qualifier qualifiers() pure const nothrow
    {
        return _qualifiers;
    }

    /**
    * Determines whether an instance of a specified type "other" can be assigned to a variable of 
    * the type represented in this Rtti.
    *
    * Params:
    *     other = The type to compare with the current type.
    *
    * Returns:
    *     true if any of the following conditions is true:
    *         - "other" and the current Rtti instance represent the same type
    *         - "other" is derived either directly or indirectly from the current instance. 
    *           "other" is derived directly from the current instance if it inherits from the 
    *           current instance; "other" is derived indirectly from the current instance if it 
    *           inherits from a succession of one or more classes that inherit from the current 
    *           instance.
    *         - The current instance is an interface that "other" implements.
    *         - "other" is a generic type parameter, and the current instance represents one 
    *           of the constraints of "other".
    *     false if none of these conditions are true, or if "other" is null.
    */
    bool isAssignableFrom(immutable(Rtti) other) const { return false; }

    /**
    * Determines whether an instance of the specified type "other" describes to the same type as this instance.
    *
    * Params:
    *     other = The type to compare with the current type.
    *
    * Returns:
    *     true if any of the following conditions is true:
    *         - "other" and the current Rtti instance represent the same type
    *         - ""
    */
    bool isSameType(immutable(Rtti) other) pure const nothrow
    {
        return (this is other) 
            || (other.type == type 
                && other.size == size 
                && other._qualifiers == _qualifiers);
    }

    bool opEquals(immutable(Rtti) other) pure const nothrow
    {
        return isSameType(other);
    }

    /**
    * 
    * Returns: string representation of this type, same as name property
    */
    override string toString() pure const nothrow
    {
        return name;
    }

    // Default constructor is disabled
    @disable this();

    // Protected constructor, use getRtti to create instance of Rtti
    protected immutable this(const string name, size_t size, const(void)* initPtr, Type type, Rtti.Qualifier qualifiers)
    {
        assert(name !is null);

        _name = name;
        _size = size;
        _initPtr = cast(immutable(void)*) initPtr;
        _type = type;
        _qualifiers = qualifiers;
    }

    protected bool canImplicitCastQualifiersToThis(Qualifier q) pure const nothrow
    {
        if (q == Qualifier.None)
        {
            return _qualifiers == Qualifier.None 
                || _qualifiers == Qualifier.Const;
        }
        else if (q == Qualifier.Const)
        {
            return _qualifiers == Qualifier.Const;
        }
        else if (q == Qualifier.Shared)
        {
            return _qualifiers == Qualifier.Shared 
                || _qualifiers == Qualifier.ConstShared;
        }
        else if (q == Qualifier.Inout)
        {
            return _qualifiers == Qualifier.Const 
                || _qualifiers == Qualifier.Inout 
                || _qualifiers == Qualifier.ConstInout;
        }
        else if (q == Qualifier.ConstShared)
        {
            return _qualifiers == Qualifier.ConstShared;
        }
        else if (q == Qualifier.ConstInout)
        {
            return _qualifiers == Qualifier.Const 
                || _qualifiers == Qualifier.ConstInout;
        }
        else if (q == Qualifier.InoutShared)
        {
            return _qualifiers == Qualifier.ConstShared 
                || _qualifiers == Qualifier.InoutShared
                || _qualifiers == Qualifier.ConstInoutShared;
        }
        else if (q == Qualifier.ConstInoutShared)
        {
            return _qualifiers == Qualifier.ConstShared 
                || _qualifiers == Qualifier.ConstInoutShared;
        }

        return _qualifiers == Qualifier.Const
            || _qualifiers == Qualifier.ConstShared
            || _qualifiers == Qualifier.ConstInout
            || _qualifiers == Qualifier.ConstInoutShared
            || _qualifiers == Qualifier.Immutable;
    }

private:
    string       _name;
    size_t       _size;
    Type         _type;
    const(void)* _initPtr;
    Qualifier    _qualifiers;
}

class RttiIntegerType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Same type check
        if (isSameType(other))
            return true;

        // Qualifiers check
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        if (other.type == Rtti.Type.Integer && other.size <= this.size)
            return true;

        if (other.type == Rtti.Type.Enum && 
            (cast(immutable(RttiEnumType))(other)).innerType.type == Rtti.Type.Integer)
        {
            return true;
        }

        return false;
    }

    override bool isSameType(immutable(Rtti) other) pure const nothrow
    {
        return super.isSameType(other) 
            && ((cast(immutable(RttiIntegerType))other).signed == signed);
    }

    @property bool signed() pure const nothrow 
    { 
        return _signed; 
    }

    // Protected constructor, use getRtti to create instance of RttiIntegerType
    protected immutable this(const string name, size_t size, const(void)* initPtr, bool signed, Rtti.Qualifier qualifiers)
    {
        super(name, size, initPtr, Rtti.Type.Integer, qualifiers);
        _signed = signed;
    }

    private bool _signed;
}

class RttiFloatType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Same type check
        if (isSameType(other))
            return true;

        // Qualifiers check
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        if (other.type == Rtti.Type.Float && other.size <= this.size)
            return true;

        if (other.type == Rtti.Type.Integer)
            return true;

        if (other.type == Rtti.Type.Enum)
        {
            auto eType = (cast(immutable(RttiEnumType))(other)).innerType;
            
            if (eType.type == Rtti.Type.Integer)
                return true;
            if (eType.type == Rtti.Type.Float && eType.size <= this.size)
                return true; 
        }

        return false;
    }

    // Protected constructor, use RttiFactory to create instance of RttiFloatType
    protected immutable this(const string name, size_t size, const(void)* initPtr, Rtti.Qualifier qualifiers)
    {
        super(name, size, initPtr, Rtti.Type.Float, qualifiers);
    }
}

class RttiEnumType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Same type check
        if (isSameType(other))
            return true;

        // Qualifiers check
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        return false;
    }

    @property immutable(Rtti) innerType() const pure nothrow 
    { 
        return _innerType; 
    }

    @property const(string[]) names() const pure nothrow
    {
        return _enumValues.names;
    }

    @property const(void*[]) values() const pure nothrow
    {
        return _enumValues.values;
    }

    override bool isSameType(immutable(Rtti) other) pure const nothrow
    {
        return super.isSameType(other) && other.name == name;
    }

protected:
    // Protected constructor, use getRtti to create instance of RttiEnumType
    immutable this(const string name, const(void)* initPtr, immutable(Rtti) innerType, immutable(EnumValues) enumValues, Rtti.Qualifier qualifiers)
    {
        super(name, innerType.size, initPtr, Rtti.Type.Enum, qualifiers);

        _innerType = innerType;
        _enumValues = enumValues;
    }

    struct EnumValues 
	{
        const(string)[] names;
        const(void)*[]  values;
    }

    static __gshared EnumValues[string] s_enumValuesRegistry;

private:
	immutable(Rtti) _innerType;
    EnumValues      _enumValues;
}

class RttiArrayType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Same type check
        if (isSameType(other))
            return true;

        if (type != Rtti.Type.StaticArray && other.type == Rtti.Type.Null)
            return true;

        // Qualifiers check
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        if (type == Rtti.Type.StaticArray && other.size != size)
            return false;

        return other.type == this.type && (cast(immutable(RttiArrayType))(other)).elementType is elementType;
    }

    override bool isSameType(immutable(Rtti) other) pure const nothrow
    {
        return super.isSameType(other) 
            && (cast(immutable(RttiArrayType)) other)._elementType.isSameType(_elementType);
    }

    @property immutable(Rtti) elementType() pure const nothrow
    {
        return _elementType;
    }

    // Protected constructor, use getRtti to create instance of RttiArrayType
    protected immutable this(const string name, 
                             size_t size, 
							 const(void)* initPtr, 
                             Rtti.Type type, 
                             immutable(Rtti) elementType, 
                             Rtti.Qualifier qualifiers)
    {
        assert(type == Rtti.Type.StaticArray ||
               type == Rtti.Type.DynamicArray ||
               type == Rtti.Type.AssociativeArray);

        super(name, size, initPtr, type, qualifiers);
        _elementType = elementType;
    }

    private immutable(Rtti) _elementType;
}

class RttiAssociativeArrayType : RttiArrayType
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        return super.isAssignableFrom(other)
            && (cast(immutable(RttiAssociativeArrayType))(other)).keyType.isSameType(keyType);
    }

    @property immutable(Rtti) keyType() pure const nothrow
    {
        return _keyType;
    }

    override bool isSameType(immutable(Rtti) other) pure const nothrow
    {
        return super.isSameType(other) 
            && (cast(immutable(RttiAssociativeArrayType)) other)._keyType.isSameType(_keyType);
    }

    // Protected constructor, use getRtti to create instance of RttiAssociativeArrayType
    protected immutable this(const string name, 
                             size_t size, 
							 const(void)* initPtr, 
                             immutable(Rtti) elementType, 
                             immutable(Rtti) keyType, 
                             Rtti.Qualifier qualifiers)
    {
        super(name, size, initPtr, Rtti.Type.AssociativeArray, elementType, qualifiers);
        _keyType = keyType;
    }

    private immutable(Rtti) _keyType;
}

class RttiFunctionType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Null type check
        if (other.type == Rtti.Type.Null)
            return true;

        // Qualifiers check
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        if (other.type == Rtti.Type.Function) 
        {
            immutable(RttiFunctionType) rhs = cast(immutable(RttiFunctionType))(other);

            // Context pointer check
            if (hasContextPointer != rhs.hasContextPointer)
                return false;

            // Return type check
            if (!returnType.isAssignableFrom(rhs.returnType))
                return false;

            // Parameters check
            if (rhs.parameters.length != _parameters.length)
                return false;

            for (uint i = 0; i < _parameters.length; i++)
            {
                if (!_parameters[i].isAssignableFrom(rhs.parameters[i]))
                    return false;
            }
        } 
        else
            return false;

        return true;
    }

    @property bool hasContextPointer() pure const nothrow 
    {
        return _hasContextPtr;
    }

    @property immutable(Rtti)[] parameters() pure const 
    { 
        return _parameters;
    }

    @property immutable(Rtti) returnType() pure const nothrow 
    {
        return _returnType;
    }

    override bool isSameType(immutable(Rtti) other) pure const nothrow
    {
        immutable(RttiFunctionType) otherRttiFunc = cast(immutable(RttiFunctionType)) other;
        bool result = super.isSameType(other) 
                    && otherRttiFunc._returnType.isSameType(_returnType)
                    && _parameters.length == otherRttiFunc._parameters.length;
        
        if (result) 
        {
            for (uint i = 0; i < _parameters.length; i++)
            {
                if (!otherRttiFunc._parameters[i].isSameType(_parameters[i]))
                    return false;
            }
        }

        return result;
    }

    // Protected constructor, use getRtti to create instance of RttiFunctionType
    protected immutable this(const string name, 
                             size_t size, 
							 const(void)* initPtr, 
                             bool hasContextPointer, 
                             immutable(Rtti) returnType, 
                             immutable(Rtti)[] parameters, 
                             Rtti.Qualifier qualifiers)
    {
        assert(returnType);

        super(name, size, initPtr, Rtti.Type.Function, qualifiers);
        _hasContextPtr = hasContextPointer;
        _parameters = parameters;
        _returnType = returnType;
    }

private:
    bool                 _hasContextPtr;
    immutable(Rtti)      _returnType;
    immutable(Rtti)[]    _parameters;
}

class RttiClassType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Same type check
        if (isSameType(other))
            return true;

        // Null type check
        if (other.type == Rtti.Type.Null)
            return true;

        // Qualifiers check
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        return other.type == Rtti.Type.Class && isBaseOf(cast(immutable(RttiClassType)) other);
    }

    override bool isSameType(immutable(Rtti) other) pure const nothrow
    {
        return super.isSameType(other) && other.name == name;
    }

    bool isBaseOf(immutable(RttiClassType) derived) pure const nothrow
    {
        immutable(RttiClassType)[] stack;
        foreach (base; derived.baseTypes)
            stack ~= base;

        while (stack.length > 0)
        {
            immutable(RttiClassType) baseClass = stack[stack.length - 1];
            if (isSameType(baseClass))
                return true;

            --stack.length;
            foreach (base; baseClass.baseTypes)
                stack ~= base;
        }

        return false;
    }

    @property immutable(RttiClassType) baseClass() pure const nothrow
	{
        return _baseClass;
	}

    @property immutable(RttiClassType)[] baseTypes() pure const nothrow
    {
        return _baseTypes;
    }

    @property bool isInterface() pure const nothrow
    {
        return _isInterface;
    }

   /**
    * Names of the class's own public event accessors (@event members).
    * Events of base classes live on the base classes' RTTI: walk baseClass
    * to collect the full set.
    */
    @property const(string[]) eventNames() pure const nothrow
    {
        return _eventNames;
    }

    // Protected constructor, use getRtti to create instance of RttiClassType
    protected immutable this(const string name, 
                             size_t size, 
							 const(void)* initPtr,                             
                             immutable(RttiClassType)[] baseTypes, 
                             immutable(RttiClassType) baseClass,
                             bool isInterface,
                             immutable(string[]) eventNames,
                             Rtti.Qualifier qualifiers)
    {
        super(name, size, initPtr, Rtti.Type.Class, qualifiers);
        _baseTypes = baseTypes;
        _baseClass = baseClass;
        _isInterface = isInterface;
        _eventNames = eventNames;
    }

private:
    immutable(RttiClassType)[] _baseTypes;
    immutable(RttiClassType) _baseClass;
    bool _isInterface;
    string[] _eventNames;
}

class RttiStructType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Same type check
        if (isSameType(other))
            return true;

        // Qualifiers check
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        return other.type == Rtti.Type.Struct 
            && other.name == name
            && other.size == size;
    }

    override bool isSameType(immutable(Rtti) other) pure const nothrow
    {
        return super.isSameType(other) && other.name == name;
    }

    protected immutable this(const string name, 
                             size_t size, 
							 const(void)* initPtr, 
                             Rtti.Qualifier qualifiers)
    {
        super(name, size, initPtr, Rtti.Type.Struct, qualifiers);
    }
}

class RttiPointerType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Same type check
        if (this is other)
            return true;

        // Null type check
        if (other.type == Rtti.Type.Null)
            return true;

        // Qualifiers check
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        return other.type == Rtti.Type.Pointer && (cast(immutable(RttiPointerType)) other).base.isAssignableFrom(base);
    }

    @property immutable(Rtti) base() pure const nothrow
    {
        return _base;
    }

    protected immutable this(const string name, 
                             size_t size, 
							 const(void)* initPtr, 
                             immutable(Rtti) base, 
                             Rtti.Qualifier qualifiers)
    {
        super(name, size, initPtr, Rtti.Type.Pointer, qualifiers);
        _base = base;
    }

    private immutable(Rtti) _base;
}

template GetBaseType(T)
{
    static if (is(T : U*, U)) // Проверяем, является ли T указателем
    {
        alias GetBaseType = U; // ElementType получает тип элемента, Unqual убирает квалификаторы
    }
    else static if (is(T : U[], U)) // Проверяем, является ли T массивом
    {
        alias GetBaseType = U; // ElementType получает тип элемента, Unqual убирает квалификаторы
    }
    else
    {
        // Если T не является указателем или массивом, возвращаем T
        alias GetBaseType = T;
    }
}

/**
 *
 */
auto getRtti(T)(T t)
{
    return getRtti!T;
}

import std.meta;

/**
 * Returns the canonical Rtti instance describing T.
 *
 * The result is memoized per type, so repeated calls return the very same
 * immutable instance.  This keeps reference-identity ('is') comparisons of
 * Rtti objects valid and avoids re-allocating type information on every call.
 *
 * During CTFE (for example, when used in a field initializer) memoization is
 * bypassed, since __gshared storage and synchronized blocks are unavailable
 * at compile time.
 */
auto getRtti(T)()
{
    if (__ctfe)
        return makeRtti!T();

    import std.typecons : Rebindable;

    alias R = typeof(makeRtti!T());
    __gshared Rebindable!R instance;  // mutable reference, immutable target
    static bool instantiated;         // thread-local fast-path guard

    if (!instantiated)
    {
        synchronized
        {
            if (instance.get is null)
            {
                instance = makeRtti!T();
                // Only unqualified classes: typeid(const C) is a
                // TypeInfo_Const without .name, and a live object's
                // typeid(this) always names the unqualified type anyway.
                static if (is(T == class) && is(T == Unqual!T))
                    registerClassRtti(typeid(T).name, instance.get);
            }
            instantiated = true;
        }
    }

    return instance.get;
}

private __gshared RttiClassType[string] s_classRttiRegistry;

/**
 * Looks up the RttiClassType registered for a class by its runtime type name
 * (as returned by typeid(obj).name).  Returns null when no RTTI has been
 * created for that type yet (for example, a type that never registered a
 * property).  This lets a live object resolve its own type information.
 */
immutable(RttiClassType) rttiForName(string typeName)
{
    synchronized (RttiClassType.classinfo)
    {
        if (auto p = typeName in s_classRttiRegistry)
            return cast(immutable(RttiClassType)) *p;
    }
    return null;
}

private void registerClassRtti(string typeName, immutable(RttiClassType) rtti)
{
    synchronized (RttiClassType.classinfo)
    {
        s_classRttiRegistry[typeName] = cast(RttiClassType) rtti;
    }
}

private auto makeRtti(T)()
{
    static if (is(immutable T == T))
        immutable Rtti.Qualifier qualifiers = Rtti.Qualifier.Immutable;
    else
        immutable Rtti.Qualifier qualifiers = cast(Rtti.Qualifier)((is(const T == T) << 1) | (is(inout T == T) << 2) | (is(shared T == T) << 3));

    static if (is(T == void))
    {
        return new immutable(Rtti)("void", 0, null, Rtti.Type.Void, Rtti.Qualifier.None);
    }
    else static if (is(T == typeof(null)))
    {
        return new immutable(Rtti)("typeof(null)", 0, null, Rtti.Type.Null, Rtti.Qualifier.None);
    }
    else static if (is(T == enum))
    {
        auto base = getRtti!(OriginalType!T);
        string fullName = fullyQualifiedName!T;
		RttiEnumType.EnumValues* eValues = (fullName in RttiEnumType.s_enumValuesRegistry); 

        if (!eValues)
		{
            eValues = new RttiEnumType.EnumValues;

			foreach (memberName; __traits(allMembers, T))
			{
				enum member = __traits(getMember, T, memberName);
				eValues.names ~= memberName;

				auto buf = new T;
				*buf = member;

				eValues.values ~= cast(void*) buf;
			}

            RttiEnumType.s_enumValuesRegistry[fullName] = *eValues; 
		}

        return new immutable(RttiEnumType)(fullName, 
										   typeid(T).initializer.ptr, 
										   base, 
										   cast(immutable(RttiEnumType.EnumValues)) *eValues, 
										   qualifiers);
    }
    else static if (__traits(isIntegral, T))
    {
        return new immutable(RttiIntegerType)(fullyQualifiedName!T, T.sizeof, typeid(T).initializer.ptr, isSigned!T, qualifiers);
    }
    else static if (__traits(isFloating, T))
    {
        return new immutable(RttiFloatType)(fullyQualifiedName!T, T.sizeof, typeid(T).initializer.ptr, qualifiers);
    }
    else static if (__traits(isStaticArray, T))
    {
        auto elementType = getRtti!(GetBaseType!T);
        return new immutable(RttiArrayType)(fullyQualifiedName!T, 
											T.sizeof, 
											typeid(T).initializer.ptr, 
											Rtti.Type.StaticArray, 
											elementType, 
											qualifiers);
    }
    else static if (isDynamicArray!T)
    {
        auto elementType = getRtti!(GetBaseType!T);
        return new immutable(RttiArrayType)(fullyQualifiedName!T, 
											T.sizeof, 
											typeid(T).initializer.ptr, 
											Rtti.Type.DynamicArray, 
											elementType, 
											qualifiers);
    }
    else static if (is(T == U[K], U, K))
    {
        auto elementType = getRtti!U;
        auto keyType = getRtti!K;
        return new immutable(RttiAssociativeArrayType)(fullyQualifiedName!T, 
													   T.sizeof, 
													   typeid(T).initializer.ptr, 
													   elementType, 
													   keyType, 
													   qualifiers);
    }
    else static if (is(T == class) || is(T == interface))
    {
        // Base types
        immutable(RttiClassType)[] baseTypes;
        RttiClassType baseClass;
        foreach (BT; BaseTypeTuple!T)
		{
            baseTypes ~= cast(immutable(RttiClassType))(getRtti!BT);
            if (is(BT == class))
                baseClass = cast(RttiClassType) getRtti!BT;
		}

        // Collect the class's own members annotated with @event, so the
        // JUICE runtime and tooling can discover events by reflection.
        string[] eventNames;
        static foreach (memberName; __traits(derivedMembers, T))
        {{
            bool isEventMember = false;

            static if (__traits(compiles, __traits(getOverloads, T, memberName)))
            {
                static foreach (overload; __traits(getOverloads, T, memberName))
                {
                    static if (__traits(compiles, hasUDA!(overload, event)))
                    {
                        static if (hasUDA!(overload, event))
                            isEventMember = true;
                    }
                }
            }

            if (isEventMember)
                eventNames ~= memberName;
        }}

        return new immutable(RttiClassType)(fullyQualifiedName!T, 
											T.sizeof, 
											typeid(T).initializer.ptr, 
											baseTypes, 
											cast(immutable(RttiClassType)) baseClass, 
											is(T == interface), 
												cast(immutable(string[])) eventNames, 
											qualifiers);
    }
    else static if (is(T == struct))
    {
        return new immutable(RttiStructType)(fullyQualifiedName!T, 
											 T.sizeof, 
											 typeid(T).initializer.ptr, 
											 qualifiers);
    }
    else static if (isSomeFunction!T)
    {
        immutable(Rtti) rType = getRtti!(ReturnType!T);
        alias pTypes = Parameters!T;
        string name = rType.toString;
        immutable(Rtti)[] parameters;

        static if (isFunctionPointer!T)
            name ~= " function(";
        else static if (isDelegate!T)
            name ~= " delegate(";

        foreach (pType; pTypes)
        {
            parameters ~= getRtti!pType;
            if (parameters.length == 1)
                name ~= parameters[parameters.length - 1].name;
            else 
                name ~= (", " ~ parameters[parameters.length - 1].name);
        }

        name ~= ")";

        return new immutable(RttiFunctionType)(name, 
											   T.sizeof, 
											   typeid(T).initializer.ptr, 
											   isDelegate!T, 
											   rType, 
											   parameters, 
											   qualifiers);
    }
    else static if (isPointer!T)
    {
        auto baseType = getRtti!(GetBaseType!T);
        return new immutable(RttiPointerType)(fullyQualifiedName!T, 
											  T.sizeof, 
											  typeid(T).initializer.ptr, 
											  baseType, 
											  qualifiers);
    }
    else
        static assert(false, "Unknown type: " ~ fullyQualifiedName!T);
}

unittest 
{
    enum E { zero, one, two }
    auto eti = getRtti!E;
    assert(eti.names == ["zero", "one", "two"]);
    assert(*(cast(const(E)*) eti.values[0]) == E.zero);
    assert(*(cast(const(E)*) eti.values[1]) == E.one);
    assert(*(cast(const(E)*) eti.values[2]) == E.two);

    auto ti = getRtti!(int);
    auto ti2 = getRtti!(int);
    auto lti = getRtti!(long);
    auto ulti = getRtti!(ulong);

    assert(ti.toString() == "int");
    assert(ti == ti2);
    assert(ti.isAssignableFrom(eti));
    assert(eti.isAssignableFrom(ti) == false);
    assert(lti.isAssignableFrom(ti));
    assert(ulti.isAssignableFrom(ti));
    assert(ulti.signed == false);
}

unittest
{
    auto ati = getRtti!(int[10]);
    assert(ati.type == Rtti.Type.StaticArray);
    assert(ati.elementType == getRtti!int);
    auto dati = getRtti!(float[]);
    assert(dati.type == Rtti.Type.DynamicArray);
    assert(dati.elementType == getRtti!float);
    auto sti = getRtti!string;
    assert(sti.type == Rtti.Type.DynamicArray);
    assert(sti.elementType == getRtti!(immutable char));
    assert(sti.isAssignableFrom(getRtti!(immutable(char)[])));
    assert(!sti.isAssignableFrom(getRtti!(char[])));
}

unittest
{
    alias F1 = int function(int a, bool b);
    alias F2 = int function(uint a, bool b);
    alias F3 = void function(int a, bool b);
    alias F4 = int function();

    alias D1 = int delegate(int a, bool b);

    auto ft1 = getRtti!F1;
    assert(!ft1.hasContextPointer);
    assert(ft1.name == "int function(int, bool)");
    assert(ft1.returnType.isSameType(getRtti!(int)));
    assert(ft1.parameters.length == 2);
    assert(ft1.parameters[0].isSameType(getRtti!(int)));
    assert(ft1.parameters[1].isSameType(getRtti!(bool)));
    assert(ft1.isSameType(getRtti!F1));

    auto ft2 = getRtti!F2;
    assert(ft2.name == "int function(uint, bool)");
    assert(ft2.isAssignableFrom(ft1));
    assert(ft1.isAssignableFrom(ft2));
    assert(!ft1.isSameType(ft2));

    auto ft3 = getRtti!F3;
    assert(ft3.name == "void function(int, bool)");
    assert(!ft1.isAssignableFrom(ft3));
    assert(!ft3.isAssignableFrom(ft1));
    
    auto ft4 = getRtti!F4;
    assert(ft4.name == "int function()");
    assert(ft4.parameters.length == 0);
    assert(!ft1.isAssignableFrom(ft4));
    assert(!ft4.isAssignableFrom(ft1));

    auto dt1 = getRtti!D1;
    assert(dt1.name == "int delegate(int, bool)");
    assert(!ft1.isAssignableFrom(dt1));
    assert(!dt1.isAssignableFrom(ft1));
    assert(dt1.hasContextPointer);
}

unittest
{
    class X
    {
        void xxx() {}
        abstract void f();
    }

    class A : X
    {
        override void f() {}
    }
    
    interface IA
    {
        void f1();
        void f2();
    }

    class B : A, IA
    {
        void f3() {}
        override void f1() {}
        override void f2() {}
    }

    immutable(RttiClassType) xt = getRtti!X;
    immutable(RttiClassType) at = getRtti!A;
    immutable(RttiClassType) iat = getRtti!IA;
    immutable(RttiClassType) bt = getRtti!B;

    assert(xt.isBaseOf(at));
    assert(!xt.isInterface); 
    assert(at.isBaseOf(bt));
    assert(!at.isInterface);
    assert(iat.isBaseOf(bt));
    assert(iat.isInterface);
    assert(!iat.isBaseOf(at));
    assert(at.isAssignableFrom(bt));
    assert(iat.isAssignableFrom(bt));
    assert(!bt.isAssignableFrom(at));
    assert(!bt.isAssignableFrom(iat));

    foreach (base; bt.baseTypes)
    {
        assert(base.isSameType(at) || base.isSameType(iat));
	}

    assert(at.baseClass.isSameType(xt));
    assert(bt.baseClass.isSameType(at));
}

unittest
{
    struct A
    {
        int val;
        string str;
    }

    struct B
    {
        uint val;
        string str;
    }

    auto ti1 = getRtti!A;
    auto ti2 = getRtti!B;
    assert(ti1.isSameType(getRtti!A));
    assert(!ti1.isSameType(getRtti!B));
    assert(ti1.isAssignableFrom(getRtti!A));
    assert(!ti1.isAssignableFrom(getRtti!(typeof(null))));
    assert(!ti1.isAssignableFrom(ti2));
    assert(ti2.isSameType(getRtti!B));
    assert(!ti2.isSameType(getRtti!A));
    assert(ti2.isAssignableFrom(getRtti!B));
    assert(!ti2.isAssignableFrom(ti1));
}


unittest
{
    // getRtti is memoized: repeated calls yield the very same instance, so
    // reference-identity comparisons of type information are valid.
    assert(getRtti!int is getRtti!int);
    assert(getRtti!(double[]) is getRtti!(double[]));
    assert(getRtti!(int[string]) is getRtti!(int[string]));
    assert(getRtti!int !is getRtti!uint);
}

unittest
{
    static class Q {}

    // RTTI for a qualified class type must compile, and it must not replace
    // the unqualified registry entry that live objects resolve through.
    auto plain  = getRtti!Q;
    auto constQ = getRtti!(const Q);
    assert(constQ.qualifiers == Rtti.Qualifier.Const);
    assert(rttiForName(typeid(Q).name) is plain);
}

unittest
{
    import std.algorithm : canFind;
    import cherry.core.multicast : EventAccessor, Multicast, eventAccessor;

    static class Emitter
    {
        private Multicast!(void delegate()) _onPing;
        private Multicast!(void delegate()) _onPong;

        @event @property EventAccessor!(void delegate()) onPing()
        {
            return eventAccessor(&_onPing);
        }

        @event @property EventAccessor!(void delegate()) onPong()
        {
            return eventAccessor(&_onPong);
        }

        @property int notAnEvent()
        {
            return 0;
        }
    }

    static class Silent
    {
        void method()
        {
        }
    }

    // @event members are collected into the class RTTI; everything else is
    // left alone.
    auto emitter = getRtti!Emitter;
    assert(emitter.eventNames.length == 2);
    assert(emitter.eventNames.canFind("onPing"));
    assert(emitter.eventNames.canFind("onPong"));
    assert(!emitter.eventNames.canFind("notAnEvent"));

    assert(getRtti!Silent.eventNames.length == 0);
}
