module cherry.core.rtti;
import std.traits;

class RTTI
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
        Delegate,
        Pointer
    }

    enum Qualifier : ubyte
    {
        Immutable = 0b00000001,
        Const     = 0b00000010,
        Inout     = 0b00000100,
        Shared    = 0b00001000
    }

    /**
    * Name property
    * Returns: name of the type represented in this RTTI.
    */
    @property string name() pure const nothrow 
    {
        return _name; 
    }

    /**
    * Size property
    * Returns: value of .sizeof called on the type represented in this RTTI.
    */
    @property size_t size() pure const nothrow 
    {
        return _size;
    }

    /**
    * Type property
    * Returns: generic kind of the type represented in this RTTI.
    */
    @property Type type() pure const nothrow
    {
        return _type;
    }

    /**
    * Determines whether an instance of a specified type "other" can be assigned to a variable of 
    * the type represented in this RTTI.
    *
    * Params:
    *     other = The type to compare with the current type.
    *
    * Returns:
    *     true if any of the following conditions is true:
    *         - "other" and the current RTTI instance represent the same type
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
    bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        if (this is other)
            return true;

        return false;
    }

    override string toString() pure const nothrow
    {
        return name;
    }

    // Default constructor is disabled
    @disable this();

    // Protected constructor, use RTTIFactory to create instance of RTTI
    protected this(const string name, size_t size, Type type)
    {
        assert(name !is null);

        _name = name;
        _size = size;
        _type = type;
    }

private:
    string  _name;
    size_t  _size;
    Type    _type;
}

class RTTI_Integer : RTTI
{
    override bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        if (other is null)
            return false;

        if (super.isAssignableFrom(other))
            return true;

        if (other.type == RTTI.Type.Integer && other.size >= this.size)
            return true;

        if (other.type == RTTI.Type.Enum)
            return true;

        return false;
    }

    // Protected constructor, use RTTIFactory to create instance of RTTI_integer
    protected this(const string name, size_t size)
    {
        super(name, size, RTTI.Type.Integer);
    }
}

class RTTI_Float : RTTI
{
    override bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        if (other is null)
            return false;

        if (super.isAssignableFrom(other))
            return true;

        if (other.type == RTTI.Type.Float && other.size <= this.size)
            return true;

        if (other.type == RTTI.Type.Integer)
            return true;

        if (other.type == RTTI.Type.Enum)
            return true;

        return false;
    }

    // Protected constructor, use RTTIFactory to create instance of RTTI_float
    protected this(const string name, size_t size)
    {
        super(name, size, RTTI.Type.Float);
    }
}

class RTTI_Enum : RTTI
{
    override bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        if (other is null)
            return false;

        if (super.isAssignableFrom(other))
            return true;

        return false;
    }

    @property immutable(RTTI) innerType() pure nothrow 
    { 
        return _innerType; 
    }

    // Protected constructor, use RTTIFactory to create instance of RTTI_enum
    protected this(const string name, immutable(RTTI) innerType)
    {
        super(name, innerType.size, RTTI.Type.Float);

        _innerType = innerType;
    }

    private immutable(RTTI) _innerType;
}

class RTTI_Array : RTTI
{
    override bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        if (other is null)
            return false;

        if (super.isAssignableFrom(other))
            return true;

        if (type == RTTI.Type.StaticArray && other.size != size)
            return false;

        return other.type == this.type && (cast(immutable(RTTI_Array))(other)).elementType is elementType;
    }

    @property immutable(RTTI) elementType() pure const nothrow
    {
        return _elementType;
    }

    // Protected constructor, use RTTIFactory to create instance of RTTI_Array
    protected this(const string name, size_t size, RTTI.Type type, immutable(RTTI) elementType)
    {
        assert(type == RTTI.Type.StaticArray ||
               type == RTTI.Type.DynamicArray ||
               type == RTTI.Type.AssociativeArray);

        super(name, size, type);
        _elementType = elementType;
    }

    private immutable(RTTI) _elementType;
}

class RTTI_AssociativeArray : RTTI_Array
{
    override bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        return super.isAssignableFrom(other) && (cast(immutable(RTTI_AssociativeArray))(other)).keyType is keyType; 
    }

    @property immutable(RTTI) keyType() pure const nothrow
    {
        return _keyType;
    }

    // Protected constructor, use RTTIFactory to create instance of RTTI_AssociativeArray
    protected this(const string name, size_t size, immutable(RTTI) elementType, immutable(RTTI) keyType)
    {
        super(name, size, RTTI.Type.AssociativeArray, elementType);
        _keyType = keyType;
    }

    private immutable(RTTI) _keyType;
}

class RTTI_Class : RTTI
{
    override bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        if (other is null)
            return false;

        if (super.isAssignableFrom(other) || 
            other.type == RTTI.Type.Null)
        {
            return true;
        }

        return other.type == RTTI.Type.Class && isBaseOf(cast(immutable(RTTI_Class)) other);
    }

    bool isBaseOf(immutable(RTTI_Class) child) pure const nothrow
    {
        for (auto ti = cast() child; ti !is null; ti = cast() ti.base)
            if (ti is this)
                return true;

        return false;
    }

    @property immutable(RTTI_Class) base() pure const nothrow
    {
        return _base;
    }

    // Protected constructor, use RTTIFactory to create instance of RTTI_Class
    protected this(const string name, size_t size, immutable(RTTI_Class) base)
    {
        super(name, size, RTTI.Type.Class);
        _base = base;
    }

    private immutable(RTTI_Class) _base;
}

class RTTI_Delegate : RTTI
{
    override bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        if (other is null)
            return false;

        if (super.isAssignableFrom(other) || 
            other.type == RTTI.Type.Null)
        {
            return true;
        }

        return other.type == RTTI.Type.Delegate && (cast(immutable(RTTI_Delegate)) other).hasContextPointer == hasContextPointer;
    }

    @property bool hasContextPointer() pure const nothrow 
    {
        return _hasContextPtr;
    }

    // Protected constructor, use RTTIFactory to create instance of RTTI_Delegate
    protected this(const string name, size_t size, bool hasContextPointer)
    {
        super(name, size, RTTI.Type.Delegate);
        _hasContextPtr = hasContextPointer;
    }

    private bool _hasContextPtr;
}

class RTTI_Pointer : RTTI
{
    override bool isAssignableFrom(immutable(RTTI) other) pure const nothrow
    {
        if (other is null)
            return false;

        if (super.isAssignableFrom(other) || 
            other.type == RTTI.Type.Null)
        {
            return true;
        }

        return other.type == RTTI.Type.Pointer && (cast(immutable(RTTI_Pointer)) other).base.isAssignableFrom(base);
    }

    @property immutable(RTTI) base() pure const nothrow
    {
        return _base;
    }

    protected this(const string name, size_t size, immutable(RTTI) base)
    {
        super(name, size, RTTI.Type.Delegate);
        _base = base;
    }

    private immutable(RTTI) _base;
}

@trusted class RTTIFactory 
{
    /**
    * Returns the RTTIFactory instance 
    */
    static synchronized RTTIFactory get() 
    {
        if (_instance is null)
            _instance = new RTTIFactory;

        return _instance;
    }

    /**
    * This method is used to get the RTTI for null type
    *
    * Returns: The RTTI instance
    */
    immutable(RTTI) getNullRTTI()
    {
        RTTI* ti = "typeof(null)" in _rttis;
        if (ti is null)
            ti = &(_rttis["typeof(null)"] = new RTTI("typeof(null)", 0, RTTI.Type.Null));

        return cast(immutable(RTTI))(*ti);
    }
    
    /**
    * This method is used to get the RTTI for void type
    *
    * Returns: The RTTI instance
    */
    immutable(RTTI) getVoidRTTI()
    {
        RTTI* ti = "void" in _rttis;
        if (ti is null)
            ti = &(_rttis["void"] = new RTTI("void", 0, RTTI.Type.Void));

        return cast(immutable(RTTI))(*ti);
    }

    /**
    * This method is used to get the RTTI for integral type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *
    * Returns:
    *     The RTTI_Integer instance 
    */
    immutable(RTTI_Integer) getIntegerRTTI(const string name, size_t size)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_Integer(name, size));

        return cast(immutable(RTTI_Integer))(*ti);
    }

    /**
    * This method is used to get the RTTI for the floating point type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *
    * Returns:
    *     The RTTI_Float instance 
    */
    immutable(RTTI_Float) getFloatRTTI(const string name, size_t size)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_Float(name, size));

        return cast(immutable(RTTI_Float))(*ti);
    }

    /**
    * This method is used to get the RTTI for enumeration type
    *
    * Params:
    *     name = The name of the type
    *     innerType = The RTTI for the inner type of this enumeration
    *
    * Returns:
    *     The RTTI_Enum instance 
    */
    immutable(RTTI_Enum) getEnumRTTI(const string name, immutable(RTTI) innerType)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_Enum(name, innerType));

        return cast(immutable(RTTI_Enum))(*ti);
    }

    /**
    * This method is used to get the RTTI for the static array type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *     elementType = The RTTI for the array element type
    *
    * Returns:
    *     The RTTI_Array instance 
    */
    immutable(RTTI) getStaticArrayRTTI(const string name, size_t size, immutable(RTTI) elementType)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_Array(name, size, RTTI.Type.StaticArray, elementType));

        return cast(immutable(RTTI_Array))(*ti);
    }

    /**
    * This method is used to get the RTTI for the dynamic array type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *     elementType = The RTTI for the array element type
    *
    * Returns:
    *     The RTTI_Array instance 
    */
    immutable(RTTI_Array) getDynamicArrayRTTI(const string name, size_t size, immutable(RTTI) elementType)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_Array(name, size, RTTI.Type.DynamicArray, elementType));

        return cast(immutable(RTTI_Array))(*ti);
    }

    /**
    * This method is used to get the RTTI for the associative array type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *     elementType = The RTTI for the array element type
    *     keyType = The RTTI for the associative array key type
    *
    * Returns:
    *     The RTTI_AssociativeArray instance 
    */
    immutable(RTTI_AssociativeArray) getAssociativeArrayRTTI(const string name, size_t size, immutable(RTTI) elementType, immutable(RTTI) keyType)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_AssociativeArray(name, size, elementType, keyType));

        return cast(immutable(RTTI_AssociativeArray))(*ti);
    }

    /**
    * This method is used to get the RTTI for the class type
    *
    * Params:
    *     name = The name of the class
    *     size = The size in bytes for the instance of this class
    *     base = The RTTI for the class ancestor or null if it's not there
    *
    * Returns:
    *     The RTTI_Class instance 
    */
    immutable(RTTI_Class) getClassRTTI(const string name, size_t size, immutable(RTTI_Class) base)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_Class(name, size, base));

        return cast(immutable(RTTI_Class))(*ti);
    }

    /**
    * This method is used to get the RTTI for the struct type
    *
    * Params:
    *     name = The name of the record
    *     size = The size in bytes for the instance of this record
    *
    * Returns:
    *     The RTTI instance 
    */
    immutable(RTTI) getStructRTTI(const string name, size_t size)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI(name, size, RTTI.Type.Struct));

        return cast(immutable(RTTI))(*ti);
    }

    /**
    * This method is used to get the RTTI for the delegate type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of this type
    *     hasContextPointer = true if the delegate contain the pointer to the stack frame
    *
    * Returns:
    *     The RTTI_Delegate instance 
    */
    immutable(RTTI_Delegate) getDelegateRTTI(const string name, size_t size, bool hasContextPointer)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_Delegate(name, size, hasContextPointer));

        return cast(immutable(RTTI_Delegate))(*ti);
    }

    /**
    * This method is used to get the RTTI for the pointer type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of this type
    *     base = The RTTI of te pointer type
    *
    * Returns:
    *     The RTTI_Pointer instance 
    */
    immutable(RTTI_Pointer) getPointerRTTI(const string name, size_t size, immutable(RTTI) base)
    {
        RTTI* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RTTI_Pointer(name, size, base));

        return cast(immutable(RTTI_Pointer))(*ti);
    }

    private static __gshared RTTIFactory _instance;
    private RTTI[string] _rttis;
}

template ArrayElementType(T) 
{
    static if (is(T : E[], E)) {
        alias ArrayElemType = E;
    }
    else
        static assert(false, fullyQualifiedName!T ~ " is not array");
}

/**
*
*/
auto getRTTI(T)(T t)
{
    return getRTTI!T;
}

/**
*
*/
auto getRTTI(T)()
{
    RTTIFactory f = RTTIFactory.get;
    static if (is(T == typeof(null)))
        return f.getNullRTTI();
    else static if (is(T == void))
        return f.getVoidRTTI();
    else static if (__traits(isIntegral, T))
        return f.getIntegerRTTI(typeid(T).toString, T.sizeof);
    else static if (__traits(isFloating, T))
        return f.getFloatRTTI(typeid(T).toString, T.sizeof);
    else static if (is(T == enum))
    {
        auto base = getRTTI!(OriginalType!T);
        return f.getEnumRTTI(typeid(T).toString, base);
    }
    else static if (__traits(isStaticArray, T))
    {
        auto elType = getRTTI!(ArrayElementType!T);
        return f.getStaticArrayRTTI(typeid(T).toString, T.sizeof, elType);
    }
    else static if (isDynamicArray!T)
    {
        auto elType = getRTTI!(ArrayElementType!T);
        return f.getDynamicArrayRTTI(typeid(T).toString, T.sizeof, elType);
    }
    else static if (is(T == class))
    {
        RTTI_Class base = null;
        foreach_reverse (baseT; BaseClassesTuple!T)
        {
            base = cast(RTTI_Class)(f.getClassRTTI(typeid(baseT).toString, baseT.sizeof, cast(immutable(RTTI_Class))(base)));
        }

        return f.getClassRTTI(typeid(T).toString, T.sizeof, cast(immutable(RTTI_Class))(base));
    }
    else static if (is(T == struct))
        return f.getStructRTTI(typeid(T).toString, T.sizeof);
    else static if (is(T == function))
        return f.getDelegateRTTI(typeid(T).toString, T.sizeof, false);
    else static if (is(T == delegate))
        return f.getDelegateRTTI(typeid(T).toString, T.sizeof, true);
    else
        static assert(false, "Unknown type: " ~ fullyQualifiedName!T);
}