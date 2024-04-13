module cherry.core.rtti;

import std.traits;

class RttiIterator(T)
{
    struct Node 
    {
        T payload;
        Node* next;
    }

    this(Node* root)
    {
        _root = root;
    }

    @property bool empty() const 
    { 
        return !_root; 
    }

    @property T front() const
    { 
        return _root.payload; 
    }

    void popFront()
    { 
        _root = _root.next; 
    }

    private Node*  _root;
}

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
        Immutable = 0b00000001,
        Const     = 0b00000010,
        Inout     = 0b00000100,
        Shared    = 0b00001000
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
    * Type property
    * Returns: generic kind of the type represented in this Rtti.
    */
    @property Type type() pure const nothrow
    {
        return _type;
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
    bool isSameType(immutable(Rtti) other) const 
    {
        return (this is other) 
            || (other.type == type 
                && other.name == name 
                && other.size == size );
    }

    override string toString() pure const nothrow
    {
        return name;
    }

    // Default constructor is disabled
    @disable this();

    // Protected constructor, use RttiFactory to create instance of Rtti
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

class RttiIntegerType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Same type check
        if (isSameType(other))
            return true;

        if (other.type == Rtti.Type.Integer && other.size >= this.size)
            return true;

        if (other.type == Rtti.Type.Enum && 
            (cast(immutable(RttiEnumType))(other)).innerType.type == Rtti.Type.Integer)
        {
            return true;
        }

        return false;
    }

    override bool isSameType(immutable(Rtti) other) const
    {
        return super.isSameType(other) 
            || (other.type == Rtti.Type.Integer 
                && other.size == size 
                && (cast(immutable(RttiIntegerType))other).isSigned == isSigned);
    }

    @property bool isSigned() pure const nothrow 
    { 
        return _signed; 
    }

    // Protected constructor, use RttiFactory to create instance of Rttiinteger
    protected this(const string name, size_t size, bool signed)
    {
        super(name, size, Rtti.Type.Integer);
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

    override bool isSameType(immutable(Rtti) other) const
    {
        return super.isSameType(other) 
            || (other.type == Rtti.Type.Float 
                && other.size == size);
    }

    // Protected constructor, use RttiFactory to create instance of Rttifloat
    protected this(const string name, size_t size)
    {
        super(name, size, Rtti.Type.Float);
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

        return false;
    }

    @property immutable(Rtti) innerType() const pure nothrow 
    { 
        return _innerType; 
    }

    // Protected constructor, use RttiFactory to create instance of Rttienum
    protected this(const string name, immutable(Rtti) innerType)
    {
        super(name, innerType.size, Rtti.Type.Enum);

        _innerType = innerType;
    }

    private immutable(Rtti) _innerType;
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

        if (type == Rtti.Type.StaticArray && other.size != size)
            return false;

        return other.type == this.type && (cast(immutable(RttiArrayType))(other)).elementType is elementType;
    }

    @property immutable(Rtti) elementType() pure const nothrow
    {
        return _elementType;
    }

    // Protected constructor, use RttiFactory to create instance of RttiArrayType
    protected this(const string name, size_t size, Rtti.Type type, immutable(Rtti) elementType)
    {
        assert(type == Rtti.Type.StaticArray ||
               type == Rtti.Type.DynamicArray ||
               type == Rtti.Type.AssociativeArray);

        super(name, size, type);
        _elementType = elementType;
    }

    private immutable(Rtti) _elementType;
}

class RttiAssociativeArrayType : RttiArrayType
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        return super.isAssignableFrom(other) && (cast(immutable(RttiAssociativeArrayType))(other)).keyType is keyType; 
    }

    @property immutable(Rtti) keyType() pure const nothrow
    {
        return _keyType;
    }

    // Protected constructor, use RttiFactory to create instance of RttiAssociativeArrayType
    protected this(const string name, size_t size, immutable(Rtti) elementType, immutable(Rtti) keyType)
    {
        super(name, size, Rtti.Type.AssociativeArray, elementType);
        _keyType = keyType;
    }

    private immutable(Rtti) _keyType;
}

class RttiFunctionType : Rtti
{
    alias ParamsIterator = RttiIterator!(immutable(Rtti));

    enum Attributes : uint
    {
        // pure, nothrow, @nogc, @property, @system, @trusted, @safe, ref and @live
        aPure      = 1,
        aNothrow   = 2,
        aNogc      = 4,
        aProperty  = 6,
        aSystem    = 8,
        aTrusted   = 16,
        aSafe      = 32,
        aRef       = 64,
        aLive      = 128,
        // const, immutable, inout, shared, static
        aConst     = 256,
        aImmutable = 512,
        aInout     = 1024,
        aShared    = 2048,
        aStatic    = 4096
    }

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
            ParamsIterator rhsParameters = rhs.parameters;
            foreach (parameterType; parameters)
            {
                if (rhsParameters.empty)
                    return false;

                if (!parameterType.isAssignableFrom(rhsParameters.front))
                    return false;

                rhsParameters.popFront();
            }

            if (!rhsParameters.empty)
                return false;
        } 
        else
            return false;

        return true;
    }

    @property bool hasContextPointer() pure const nothrow 
    {
        return _hasContextPtr;
    }

    @property ParamsIterator parameters() pure const 
    { 
        return new ParamsIterator(cast(ParamsIterator.Node*)(_parametersList));
    }

    @property immutable(Rtti) returnType() pure const nothrow 
    {
        return _returnType;
    }

    @property bool isStatic() pure const nothrow
    {
        return hasAttribute(Attributes.aStatic);
    }

    bool hasAttribute(uint attribute) pure const nothrow
    {
        return (_attributes & attribute) > 0;
    }

    // Protected constructor, use RttiFactory to create instance of RttiFunctionType
    protected this(const string name, 
                   size_t size, 
                   bool hasContextPointer, 
                   immutable(Rtti) returnType, 
                   ParamsIterator.Node* parametersList,
                   uint attributes)
    {
        assert(returnType);

        super(name, size, Rtti.Type.Function);
        _hasContextPtr = hasContextPointer;
        _parametersList = parametersList;
        _returnType = returnType;
        _attributes = attributes;
    }

private:
    bool                 _hasContextPtr;
    immutable(Rtti)      _returnType;
    ParamsIterator.Node* _parametersList;
    uint                 _attributes;
}

class RttiMethodType : RttiFunctionType
{
    // Protected constructor, use RttiFactory to create instance of RttiMethodType
    protected this(const string name, 
                   size_t size,
                   string methodName,
                   void* ptr,
                   immutable(Rtti) returnType, 
                   ParamsIterator.Node* parametersList,
                   uint attributes)
    {
        super(name, 
              size, 
              !(attributes & RttiFunctionType.Attributes.aStatic), 
              returnType, 
              parametersList,
              attributes);
        
        _methodName = methodName;
        _ptr = ptr;
    }

    @property string methodName() pure const nothrow
    {
        return _methodName;
    }

    @property void* ptr() pure const nothrow
    {
        return cast(void*)(_ptr);
    }

    @property bool isProperty() pure const nothrow
    {
        return hasAttribute(RttiFunctionType.Attributes.aProperty);
    }

private:
    void*  _ptr;
    string _methodName;
}

class RttiClassType : Rtti
{
    alias MethodsIterator = RttiIterator!(immutable(RttiMethodType));
    alias BaseTypesIterator = RttiIterator!(immutable(RttiClassType));

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

        return other.type == Rtti.Type.Class && isBaseOf(cast(immutable(RttiClassType)) other);
    }

    bool isBaseOf(immutable(RttiClassType) child) pure const nothrow
    {
        
        return false;
    }

    @property BaseTypesIterator baseTypes() pure const nothrow
    {
        return new BaseTypesIterator(cast(BaseTypesIterator.Node*)(_baseTypesList));
    }

    @property MethodsIterator methods() const 
    {
        return new MethodsIterator(cast(MethodsIterator.Node*)(_methodsList));
    }

    // Protected constructor, use RttiFactory to create instance of RttiClassType
    protected this(const string name, 
                   size_t size, 
                   BaseTypesIterator.Node* baseTypesList, 
                   MethodsIterator.Node* methodsList)
    {
        super(name, size, Rtti.Type.Class);
        _baseTypesList = baseTypesList;
        _methodsList = methodsList;
    }

private:
    BaseTypesIterator.Node* _baseTypesList;
    MethodsIterator.Node*   _methodsList;
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

        return other.type == Rtti.Type.Pointer && (cast(immutable(RttiPointerType)) other).base.isAssignableFrom(base);
    }

    @property immutable(Rtti) base() pure const nothrow
    {
        return _base;
    }

    protected this(const string name, size_t size, immutable(Rtti) base)
    {
        super(name, size, Rtti.Type.Function);
        _base = base;
    }

    private immutable(Rtti) _base;
}

@trusted class RttiFactory 
{
    /**
    * Returns the RttiFactory instance 
    */
    static synchronized RttiFactory get() 
    {
        if (_instance is null)
            _instance = new RttiFactory;

        return _instance;
    }

    static synchronized Object createInstance(const string className)
    {
        return null;
    }

protected:
    /**
    * This method is used to get the Rtti for null type
    *
    * Returns: The Rtti instance
    */
    immutable(Rtti) getNullRtti()
    {
        Rtti* ti = "typeof(null)" in _rttis;
        if (ti is null)
            ti = &(_rttis["typeof(null)"] = new Rtti("typeof(null)", 0, Rtti.Type.Null));

        return cast(immutable(Rtti))(*ti);
    }
    
    /**
    * This method is used to get the Rtti for void type
    *
    * Returns: The Rtti instance
    */
    immutable(Rtti) getVoidRtti()
    {
        Rtti* ti = "void" in _rttis;
        if (ti is null)
            ti = &(_rttis["void"] = new Rtti("void", 0, Rtti.Type.Void));

        return cast(immutable(Rtti))(*ti);
    }

    /**
    * This method is used to get the Rtti for integral type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *
    * Returns:
    *     The RttiIntegerType instance 
    */
    immutable(RttiIntegerType) getIntegerRtti(const string name, size_t size, bool signed)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiIntegerType(name, size, signed));

        return cast(immutable(RttiIntegerType))(*ti);
    }

    /**
    * This method is used to get the Rtti for the floating point type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *
    * Returns:
    *     The RttiFloatType instance 
    */
    immutable(RttiFloatType) getFloatRtti(const string name, size_t size)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiFloatType(name, size));

        return cast(immutable(RttiFloatType))(*ti);
    }

    /**
    * This method is used to get the Rtti for enumeration type
    *
    * Params:
    *     name = The name of the type
    *     innerType = The Rtti for the inner type of this enumeration
    *
    * Returns:
    *     The RttiEnumType instance 
    */
    immutable(RttiEnumType) getEnumRtti(const string name, immutable(Rtti) innerType)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiEnumType(name, innerType));

        return cast(immutable(RttiEnumType))(*ti);
    }

    /**
    * This method is used to get the Rtti for the static array type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *     elementType = The Rtti for the array element type
    *
    * Returns:
    *     The RttiArrayType instance 
    */
    immutable(Rtti) getStaticArrayRtti(const string name, size_t size, immutable(Rtti) elementType)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiArrayType(name, size, Rtti.Type.StaticArray, elementType));

        return cast(immutable(RttiArrayType))(*ti);
    }

    /**
    * This method is used to get the Rtti for the dynamic array type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *     elementType = The Rtti for the array element type
    *
    * Returns:
    *     The RttiArrayType instance 
    */
    immutable(RttiArrayType) getDynamicArrayRtti(const string name, size_t size, immutable(Rtti) elementType)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiArrayType(name, size, Rtti.Type.DynamicArray, elementType));

        return cast(immutable(RttiArrayType))(*ti);
    }

    /**
    * This method is used to get the Rtti for the associative array type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of the type
    *     elementType = The Rtti for the array element type
    *     keyType = The Rtti for the associative array key type
    *
    * Returns:
    *     The RttiAssociativeArrayType instance 
    */
    immutable(RttiAssociativeArrayType) getAssociativeArrayRtti(const string name, size_t size, immutable(Rtti) elementType, immutable(Rtti) keyType)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiAssociativeArrayType(name, size, elementType, keyType));

        return cast(immutable(RttiAssociativeArrayType))(*ti);
    }

    /**
    * This method is used to get the Rtti for the class type
    *
    * Params:
    *     name = The name of the class
    *     size = The size in bytes for the instance of this class
    *     base = The Rtti for the class ancestor or null if it's not there
    *
    * Returns:
    *     The RttiClassType instance 
    */
    immutable(RttiClassType) getClassRtti(const string name, 
                                          size_t size, 
                                          RttiClassType.BaseTypesIterator.Node* baseTypesList, 
                                          RttiClassType.MethodsIterator.Node* methodsList)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiClassType(name, size, baseTypesList, methodsList));

        return cast(immutable(RttiClassType))(*ti);
    }

    /**
    * This method is used to get the Rtti for the struct type
    *
    * Params:
    *     name = The name of the record
    *     size = The size in bytes for the instance of this record
    *
    * Returns:
    *     The Rtti instance 
    */
    immutable(Rtti) getStructRtti(const string name, size_t size)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new Rtti(name, size, Rtti.Type.Struct));

        return cast(immutable(Rtti))(*ti);
    }

    /**
    * This method is used to get the Rtti for the function type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of this type
    *     hasContextPointer = true if the function contain the pointer to the stack frame
    *
    * Returns:
    *     The RttiFunctionType instance 
    */
    immutable(RttiFunctionType) getFunctionRtti(const string name, 
                                                size_t size, 
                                                bool hasContextPointer, 
                                                immutable(Rtti) returnType, 
                                                RttiFunctionType.ParamsIterator.Node* parametersList,
                                                uint attributes)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiFunctionType(name, size, hasContextPointer, returnType, parametersList, attributes));

        return cast(immutable(RttiFunctionType))(*ti);
    }

    /**
    * This method is used to get the Rtti for the class method type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of this type
    *     hasContextPointer = true if the function contain the pointer to the stack frame
    *
    * Returns:
    *     The RttiFunctionType instance 
    */
    immutable(RttiMethodType) getMethodRtti(const string name, 
                                            size_t size, 
                                            string methodName,
                                            void* ptr,
                                            immutable(Rtti) returnType, 
                                            RttiFunctionType.ParamsIterator.Node* parametersList,
                                            uint attributes)
    {
        return cast(immutable(RttiMethodType))(new RttiMethodType(name, size, methodName, ptr, returnType, parametersList, attributes));
    }

    /**
    * This method is used to get the Rtti for the pointer type
    *
    * Params:
    *     name = The name of the type
    *     size = The size in bytes for the instance of this type
    *     base = The Rtti of te pointer type
    *
    * Returns:
    *     The RttiPointerType instance 
    */
    immutable(RttiPointerType) getPointerRtti(const string name, size_t size, immutable(Rtti) base)
    {
        Rtti* ti = name in _rttis;
        if (ti is null)
            ti = &(_rttis[name] = new RttiPointerType(name, size, base));

        return cast(immutable(RttiPointerType))(*ti);
    }

    private static __gshared RttiFactory _instance;
    private Rtti[string] _rttis;
}

private template ArrayElementType(T) 
{
    static if (is(T : E[], E)) {
        alias ArrayElementType = E;
    }
    else
        static assert(false, fullyQualifiedName!T ~ " is not array");
}

private static uint getFuncAttributes(T)()
{
    static if ( isFunctionPointer!T || isDelegate!T)
    {
        uint attrs;
        auto attributes = __traits(getFunctionAttributes, T);

        foreach (attr; attributes)
        {
            switch (attr)
            {
                case "pure":
                    attrs &= RttiFunctionType.Attributes.aPure;
                    break;

                case "nothrow":
                    attrs &= RttiFunctionType.Attributes.aNothrow;
                    break;

                case "@nogc":
                    attrs &= RttiFunctionType.Attributes.aNogc;
                    break;

                case "@property":
                    attrs &= RttiFunctionType.Attributes.aProperty;
                    break;

                case "@system":
                    attrs &= RttiFunctionType.Attributes.aSystem;
                    break;

                case "@trusted":
                    attrs &= RttiFunctionType.Attributes.aTrusted;
                    break;

                case "@safe":
                    attrs &= RttiFunctionType.Attributes.aSafe;
                    break;

                case "ref":
                    attrs &= RttiFunctionType.Attributes.aRef;
                    break;

                case "@live":
                    attrs &= RttiFunctionType.Attributes.aLive;
                    break;

                case "const":
                    attrs &= RttiFunctionType.Attributes.aConst;
                    break;

                case "immutable":
                    attrs &= RttiFunctionType.Attributes.aImmutable;
                    break;

                case "inout":
                    attrs &= RttiFunctionType.Attributes.aInout;
                    break;

                case "shared":
                    attrs &= RttiFunctionType.Attributes.aShared;
                    break;

                default:
                    assert(false, "unknown attribute");
            }
        }

        static if (__traits(isStaticFunction, T))
        {
            attrs &= RttiFunctionType.Attributes.aStatic;
        }

        return attrs;
    }
    else
        static assert(false, fullyQualifiedName!T ~ " is not function or class method");
}

/**
*
*/
auto getRtti(T)(T t)
{
    return getRtti!T;
}

/**
*
*/
auto getRtti(T)()
{
    RttiFactory f = RttiFactory.get;
    static if (is(T == typeof(null)))
        return f.getNullRtti();
    else static if (is(T == void))
        return f.getVoidRtti();
    else static if (is(T == enum))
    {
        auto base = getRtti!(OriginalType!T);
        return f.getEnumRtti(fullyQualifiedName!T, base);
    }
    else static if (__traits(isIntegral, T))
        return f.getIntegerRtti(fullyQualifiedName!T, T.sizeof, isSigned!T);
    else static if (__traits(isFloating, T))
        return f.getFloatRtti(fullyQualifiedName!T, T.sizeof);
    else static if (__traits(isStaticArray, T))
    {
        auto elType = getRtti!(ArrayElementType!T);
        return f.getStaticArrayRtti(fullyQualifiedName!T, T.sizeof, elType);
    }
    else static if (isDynamicArray!T)
    {
        auto elType = getRtti!(ArrayElementType!T);
        return f.getDynamicArrayRtti(fullyQualifiedName!T, T.sizeof, elType);
    }
    else static if (is(T == class))
    {
        RttiClassType.BaseTypesIterator.Node* pFirstBaseType, pLastBaseType;
        RttiClassType.MethodsIterator.Node* pFirstMethod, pLastMethod;

        // Base types
        foreach (BT; BaseTypeTuple!T)
        {
            if (!pLastBaseType)
            {
                pFirstBaseType = 
                pLastBaseType = new RttiClassType.BaseTypesIterator.Node(getRtti!BT, null);
            }
            else
            {
                pLastBaseType.next = new RttiClassType.BaseTypesIterator.Node(getRtti!BT, null);
                pLastBaseType = pLastBaseType.next;
            }
        }

        // Methods
        foreach(member; __traits(derivedMembers, T))
        {
            static if ( __traits(compiles, isSomeFunction!(__traits(getMember, B, member))) ) 
            {
                static if ( isSomeFunction!(__traits(getMember, B, member)) )
                {

                }
            }
        }

        return f.getClassRtti(fullyQualifiedName!T, T.sizeof, pFirstBaseType, pFirstMethod);
    }
    else static if (is(T == struct))
        return f.getStructRtti(fullyQualifiedName!Tg, T.sizeof);
    else static if (isSomeFunction!T)
    {
        uint attributes = getFuncAttributes!T();
        immutable(Rtti) rType = getRtti!(ReturnType!T);
        alias pTypes = Parameters!T;
        RttiFunctionType.ParamsIterator.Node* pFirst, pLast;
        string name = rType.toString;

        static if (isFunctionPointer!T)
            name ~= " function(";
        else static if (isDelegate!T)
            name ~= " delegate(";

        foreach (pType; pTypes)
        {
            if (!pLast)
            {
                pLast = 
                    pFirst = new RttiFunctionType.ParamsIterator.Node(getRtti!pType, null);
                name ~= pLast.payload.name;
            } 
            else 
            {
                pLast.next = new RttiFunctionType.ParamsIterator.Node(getRtti!pType, null);
                pLast = pLast.next;
                name ~= (", " ~ pLast.payload.name);
            }
        }

        name ~= ")";

        return f.getFunctionRtti(name, T.sizeof, isDelegate!T, rType, pFirst, attributes);
    }
    else
        static assert(false, "Unknown type: " ~ fullyQualifiedName!T);
}

unittest 
{
    enum E { zero, one, two }
    auto eti = getRtti!E;
    auto ti = getRtti!(int);
    auto ti2 = getRtti!(int);
    assert(ti.toString() == "int");
    assert(ti is ti2);
    assert(ti.isAssignableFrom(eti));
    assert(eti.isAssignableFrom(ti) == false);
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
    auto params = ft1.parameters;
    assert(params.front.isSameType(getRtti!(int)));
    params.popFront();
    assert(params.front.isSameType(getRtti!(bool)));

    auto ft2 = getRtti!F2;
    assert(ft2.name == "int function(uint, bool)");
    assert(ft2.isAssignableFrom(ft1));
    assert(ft1.isAssignableFrom(ft2));

    auto ft3 = getRtti!F3;
    assert(ft3.name == "void function(int, bool)");
    assert(!ft1.isAssignableFrom(ft3));
    assert(!ft3.isAssignableFrom(ft1));
    
    auto ft4 = getRtti!F4;
    assert(ft4.name == "int function()");
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
    class A
    {
        static void sf() {}

        @property int p1() pure const nothrow { return 0; }
        @property void p1(int v) nothrow {}

        void f() {}

        private void pf() {}
    }
    
    interface IA
    {
        void f1();
        void f2();
    }

    class B : A, IA
    {
        override void f() {}
        override void f1() {}
        override void f2() {}

        this() {}
        static this() {}

        int g() { return 0; }
        int g(int a) { return a; }

        @property int a1() const { return 1; }

        bool c() const { return true; }
    }

    

    auto bt = getRtti!B;
    auto at = getRtti!A;
    auto iat = getRtti!IA;
    auto baseTypes = bt.baseTypes;
    assert(baseTypes.front.isSameType(at));
    baseTypes.popFront();
    assert(baseTypes.front.isSameType(iat));

    assert(at.isAssignableFrom(bt));
    assert(iat.isAssignableFrom(bt));
    assert(at.findMethods("sf").front.isStatic);

    auto aprop = at.findMethods("p1");
    foreach (prop; aprop)
    {
        assert(prop.isProperty);
        if (prop.returnType.isSameType(getRtti!int))
        {
            assert(prop.parameters.empty);
            assert(prop.hasAttribute(RttiFunctionType.Attributes.aPure));
            assert(prop.hasAttribute(RttiFunctionType.Attributes.aConst));
            assert(prop.hasAttribute(RttiFunctionType.Attributes.aNothrow));
        }
        else
        {
            assert(prop.returnType.isSameType(getRtti!void));
            assert(prop.hasAttribute(RttiFunctionType.Attributes.aNothrow));
        }
    }
}