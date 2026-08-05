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
   /**
    * Whether other describes the same type as this one, disregarding the
    * qualifiers either was asked for.
    *
    * This is the question assignability wants: `immutable(Plain)` and `Plain`
    * are one type, and whether a value of one may be put where the other is
    * expected is decided separately, by what the value can reach.  isSameType
    * stays exact -- Value equality is built on it, and two Values should not
    * become equal because one of them forgot a promise.
    *
    * Both sides are compared through the instance describing them unqualified,
    * which getRtti hands to the constructor.  A static array is canonicalised
    * down to its elements, since immutable(float[4]) *is* immutable(float)[4];
    * a slice is not, so string stays distinct from char[].
    */
    bool isSameUnqualifiedType(immutable(Rtti) other) pure const nothrow
    {
        if (other is null)
            return false;

        // A null link reads as "I am the unqualified one" -- a constructor
        // cannot hand an object a reference to itself, and this saves the
        // whole registry a self-reference apiece.
        auto mine = _unqualified;
        auto theirs = other._unqualified;

        if (mine !is null)
            return theirs !is null ? mine is theirs : mine is other;

        return theirs !is null ? theirs is this : this is other;
    }

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
    protected immutable this(const string name, size_t size, const(void)* initPtr, Type type, Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        assert(name !is null);

        _name = name;
        _size = size;
        _initPtr = cast(immutable(void)*) initPtr;
        _type = type;
        _qualifiers = qualifiers;
        _unqualified = unqualified;
    }

   /**
    * Whether a value of this type can reach memory that is not part of the
    * value itself: a class reference, a pointer, the elements behind a slice.
    *
    * This is what decides whether qualifiers matter to an assignment.  Copying
    * a value that reaches nothing hands over every byte of it and nothing
    * else, so `float x = someImmutableFloat` is sound and D accepts it.
    * Copying one that does reach further hands over a second way into shared
    * memory under a different qualifier, which is why `int[] a = someImmutable`
    * is refused.
    *
    * True unless a subclass knows better: the conservative answer only ever
    * refuses an assignment that would have been allowed.
    */
    @property bool hasIndirections() pure const nothrow
    {
        return true;
    }

    protected bool canImplicitCastQualifiersToThis(Qualifier q) pure const nothrow
    {
        // Nothing is reachable through this type, so the source's qualifier
        // describes nothing that survives the copy and cannot conflict with
        // the destination's.  The matrix below is about what a value reaches;
        // where it reaches nothing, it has nothing to say.
        if (!hasIndirections)
            return true;

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

    // The instance describing this type with its qualifiers taken off, or
    // null when this is that instance.  Filled in by getRtti, which is the
    // only place that knows T.
    immutable(Rtti) _unqualified;
}

class RttiIntegerType : Rtti
{
    override @property bool hasIndirections() pure const nothrow
    {
        return false;
    }
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Qualifiers first: one the destination cannot honour settles the
        // question, whatever else the two types have in common.
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        // Then identity, with those qualifiers already accounted for.
        if (isSameUnqualifiedType(other))
            return true;

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
    protected immutable this(const string name, size_t size, const(void)* initPtr, bool signed, Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        super(name, size, initPtr, Rtti.Type.Integer, qualifiers, unqualified);
        _signed = signed;
    }

    private bool _signed;
}

class RttiFloatType : Rtti
{
    override @property bool hasIndirections() pure const nothrow
    {
        return false;
    }
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Qualifiers first: one the destination cannot honour settles the
        // question, whatever else the two types have in common.
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        // Then identity, with those qualifiers already accounted for.
        if (isSameUnqualifiedType(other))
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

    // Protected constructor, use RttiFactory to create instance of RttiFloatType
    protected immutable this(const string name, size_t size, const(void)* initPtr, Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        super(name, size, initPtr, Rtti.Type.Float, qualifiers, unqualified);
    }
}

class RttiEnumType : Rtti
{
    override @property bool hasIndirections() pure const nothrow
    {
        return _innerType.hasIndirections;
    }
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Qualifiers first: one the destination cannot honour settles the
        // question, whatever else the two types have in common.
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        // Then identity, with those qualifiers already accounted for.
        if (isSameUnqualifiedType(other))
            return true;

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
    immutable this(const string name, const(void)* initPtr, immutable(Rtti) innerType, immutable(EnumValues) enumValues, Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        super(name, innerType.size, initPtr, Rtti.Type.Enum, qualifiers, unqualified);

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
    override @property bool hasIndirections() pure const nothrow
    {
        // A static array is its elements; a slice or a map is a handle
        // on elements that live elsewhere.
        return type == Rtti.Type.StaticArray
            ? _elementType.hasIndirections
            : true;
    }
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Null goes wherever a handle goes -- but a static array is not a
        // handle, it is the elements themselves.
        if (type != Rtti.Type.StaticArray && other.type == Rtti.Type.Null)
            return true;

        // Qualifiers first: one the destination cannot honour settles the
        // question, whatever else the two types have in common.
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        // Then identity, with those qualifiers already accounted for.
        if (isSameUnqualifiedType(other))
            return true;

        if (type == Rtti.Type.StaticArray && other.size != size)
            return false;

        // isSameType and not `is`: reference identity holds only for types
        // that went through getRtti's memoization, and it would quietly answer
        // false for any that did not.
        return other.type == this.type
            && (cast(immutable(RttiArrayType))(other)).elementType.isSameType(elementType);
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
                             Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        assert(type == Rtti.Type.StaticArray ||
               type == Rtti.Type.DynamicArray ||
               type == Rtti.Type.AssociativeArray);

        super(name, size, initPtr, type, qualifiers, unqualified);
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
                             Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        super(name, size, initPtr, Rtti.Type.AssociativeArray, elementType, qualifiers, unqualified);
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
                             Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        assert(returnType);

        super(name, size, initPtr, Rtti.Type.Function, qualifiers, unqualified);
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

        // Null goes wherever a reference goes, whatever the destination
        // promises about the other end of it.
        if (other.type == Rtti.Type.Null)
            return true;

        // Qualifiers first: one the destination cannot honour settles the
        // question, whatever else the two types have in common.
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        // Then identity, with those qualifiers already accounted for.
        if (isSameUnqualifiedType(other))
            return true;

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
                             Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        super(name, size, initPtr, Rtti.Type.Class, qualifiers, unqualified);
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
    override @property bool hasIndirections() pure const nothrow
    {
        return _hasIndirections;
    }
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Qualifiers first: one the destination cannot honour settles the
        // question, whatever else the two types have in common.
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        // Then identity, with those qualifiers already accounted for.
        if (isSameUnqualifiedType(other))
            return true;

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
                             bool hasIndirections,
                             Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        super(name, size, initPtr, Rtti.Type.Struct, qualifiers, unqualified);
        _hasIndirections = hasIndirections;
    }

    // A struct's fields are not in the Rtti graph, so this cannot be worked
    // out after the fact.  std.traits knows it where the Rtti is built.
    private bool _hasIndirections;
}

class RttiPointerType : Rtti
{
    override bool isAssignableFrom(immutable(Rtti) other) const
    {
        if (!other)
            return false;

        // Null goes wherever a reference goes, whatever the destination
        // promises about the other end of it.
        if (other.type == Rtti.Type.Null)
            return true;

        // Qualifiers first: one the destination cannot honour settles the
        // question, whatever else the two types have in common.
        if (!canImplicitCastQualifiersToThis(other.qualifiers))
            return false;

        // Then identity, with those qualifiers already accounted for.
        if (isSameUnqualifiedType(other))
            return true;

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
                             Rtti.Qualifier qualifiers, immutable(Rtti) unqualified = null)
    {
        super(name, size, initPtr, Rtti.Type.Pointer, qualifiers, unqualified);
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
 * T with every qualifier removed that could not have outlived a copy of it.
 *
 * Shallow Unqual is not enough for a static array: immutable(float[4]) *is*
 * immutable(float)[4] -- a static array is its elements, so the qualifier has
 * already distributed itself over them and has to be peeled off there too.
 * Everywhere else the outer layer is the whole story, and deliberately so: a
 * slice keeps its element qualifier, because immutable(char)[] and char[] are
 * different types and one of them is string.
 */
template Unqualified(T)
{
    static if (is(T == U[N], U, size_t N))
        alias Unqualified = Unqualified!U[N];
    else
        alias Unqualified = Unqual!T;
}

/*
 * The instance describing T without the qualifiers it was asked for, or null
 * when T carries none and is therefore that instance itself.  Returning null
 * for the unqualified case is also what stops this recursing: getRtti!T would
 * otherwise re-enter itself while its own instance is still being built.
 */
private immutable(Rtti) canonicalOf(T)()
{
    static if (is(T == Unqualified!T))
        return null;
    else
        return getRtti!(Unqualified!T)();
}

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

        // The members belong to the enum, not to the qualifier it was
        // asked for, so const(Corner) and immutable(Corner) share one
        // table with Corner rather than each building a copy.
        enum string valuesKey = fullyQualifiedName!(Unqual!T);
		RttiEnumType.EnumValues* eValues = (valuesKey in RttiEnumType.s_enumValuesRegistry); 

        if (!eValues)
		{
            eValues = new RttiEnumType.EnumValues;

			foreach (memberName; __traits(allMembers, T))
			{
				enum member = __traits(getMember, T, memberName);
				eValues.names ~= memberName;

				auto buf = new Unqual!T;   // an immutable buffer cannot be written to
				*buf = member;

				eValues.values ~= cast(void*) buf;
			}

            RttiEnumType.s_enumValuesRegistry[valuesKey] = *eValues; 
		}

        return new immutable(RttiEnumType)(fullName, 
										   typeid(T).initializer.ptr, 
										   base, 
										   cast(immutable(RttiEnumType.EnumValues)) *eValues, 
										   qualifiers, canonicalOf!T());
    }
    else static if (__traits(isIntegral, T))
    {
        return new immutable(RttiIntegerType)(fullyQualifiedName!T, T.sizeof, typeid(T).initializer.ptr, isSigned!T, qualifiers, canonicalOf!T());
    }
    else static if (__traits(isFloating, T))
    {
        return new immutable(RttiFloatType)(fullyQualifiedName!T, T.sizeof, typeid(T).initializer.ptr, qualifiers, canonicalOf!T());
    }
    else static if (__traits(isStaticArray, T))
    {
        auto elementType = getRtti!(GetBaseType!T);
        return new immutable(RttiArrayType)(fullyQualifiedName!T, 
											T.sizeof, 
											typeid(T).initializer.ptr, 
											Rtti.Type.StaticArray, 
											elementType, 
											qualifiers, canonicalOf!T());
    }
    else static if (isDynamicArray!T)
    {
        auto elementType = getRtti!(GetBaseType!T);
        return new immutable(RttiArrayType)(fullyQualifiedName!T, 
											T.sizeof, 
											typeid(T).initializer.ptr, 
											Rtti.Type.DynamicArray, 
											elementType, 
											qualifiers, canonicalOf!T());
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
													   qualifiers, canonicalOf!T());
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
											qualifiers, canonicalOf!T());
    }
    else static if (is(T == struct))
    {
        return new immutable(RttiStructType)(fullyQualifiedName!T, 
											 T.sizeof, 
											 typeid(T).initializer.ptr, 
											 hasIndirections!T,
											 qualifiers, canonicalOf!T());
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
											   qualifiers, canonicalOf!T());
    }
    else static if (isPointer!T)
    {
        auto baseType = getRtti!(GetBaseType!T);
        return new immutable(RttiPointerType)(fullyQualifiedName!T, 
											  T.sizeof, 
											  typeid(T).initializer.ptr, 
											  baseType, 
											  qualifiers, canonicalOf!T());
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

enum Corner : int { topLeft, topRight, bottomLeft }

unittest
{
    // Building the RTTI of a qualified enum used to fail outright: every
    // member value was written into a buffer of the qualified type itself,
    // and an immutable one cannot be written to.
    auto plain  = getRtti!Corner;
    auto frozen = getRtti!(immutable Corner);

    assert(frozen.qualifiers == Rtti.Qualifier.Immutable);
    assert(frozen.names.length == 3);
    assert(frozen.names == plain.names, "the members belong to the enum, not to the qualifier");
    assert(frozen.innerType.type == Rtti.Type.Integer);
}

unittest
{
    // Qualifiers only matter to an assignment as far as the value can reach.
    // A float reaches nothing, so a copy of an immutable one is a plain float
    // and D accepts the assignment -- getRtti must agree with the language.
    assert(getRtti!float.isAssignableFrom(getRtti!(immutable float)));
    assert(getRtti!float.isAssignableFrom(getRtti!(const float)));
    assert(getRtti!float.isAssignableFrom(getRtti!(shared float)));
    assert(getRtti!(shared float).isAssignableFrom(getRtti!float));
    assert(getRtti!(immutable float).isAssignableFrom(getRtti!float));

    assert(getRtti!int.isAssignableFrom(getRtti!(immutable int)));
    assert(getRtti!double.isAssignableFrom(getRtti!(immutable float)));

    // An enum is as reachable as the type behind it.
    assert(getRtti!int.isAssignableFrom(getRtti!(immutable Corner)));

    // A struct of such fields is copied whole, and a static array is its
    // elements, so both answer the same way now that identity disregards the
    // qualifier the type was asked for.
    static struct Plain { float x; float y; }
    assert(getRtti!Plain.isAssignableFrom(getRtti!(immutable Plain)));
    assert(getRtti!(float[4]).isAssignableFrom(getRtti!(immutable(float[4]))));

    // A slice is a handle on elements kept elsewhere, and immutability is a
    // promise about those elements, so it has to hold.
    assert(!getRtti!(int[]).isAssignableFrom(getRtti!(immutable(int[]))));
    assert(!getRtti!(int[]).isAssignableFrom(getRtti!(const(int[]))));
    assert(!getRtti!(shared(int[])).isAssignableFrom(getRtti!(int[])));

    // Same for a class reference: two names for one object, and one of them
    // would be promising something the other could break.
    static class Node { }
    assert(!getRtti!Node.isAssignableFrom(getRtti!(immutable Node)));
}

unittest
{
    static struct Plain { float x; }
    static class Node { }

    // Identity disregards the qualifier a type was asked for...
    assert(getRtti!Plain.isSameUnqualifiedType(getRtti!(immutable Plain)));
    assert(getRtti!float.isSameUnqualifiedType(getRtti!(const float)));
    assert(getRtti!Node.isSameUnqualifiedType(getRtti!(immutable Node)));
    assert(getRtti!(float[4]).isSameUnqualifiedType(getRtti!(immutable(float[4]))));

    // ...and isSameType does not, deliberately: Value equality rests on it,
    // and two values should not become equal by forgetting a promise.
    assert(!getRtti!Plain.isSameType(getRtti!(immutable Plain)));
    assert(!getRtti!float.isSameType(getRtti!(const float)));

    // Different types stay different under either question.
    assert(!getRtti!float.isSameUnqualifiedType(getRtti!double));
    assert(!getRtti!int.isSameUnqualifiedType(getRtti!uint));

    // A slice is not canonicalised through its elements, so string keeps its
    // distance from char[].  This is the case that stops the qualifier being
    // dropped when the Rtti is built, rather than when it is compared.
    assert(!getRtti!string.isSameUnqualifiedType(getRtti!(char[])));
    assert(!getRtti!string.isAssignableFrom(getRtti!(char[])));

    // Being the same type is not being assignable: a class reference reaches
    // further than itself, so the qualifier still has to be honoured.
    assert(getRtti!Node.isSameUnqualifiedType(getRtti!(immutable Node)));
    assert(!getRtti!Node.isAssignableFrom(getRtti!(immutable Node)));
}
