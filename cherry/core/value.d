module cherry.core.value;

import cherry.core.rtti;
import std.traits;

class ValueTypeMismatchException : Exception
{
    this(immutable(Rtti) expected, immutable(Rtti) got)
    {
        super("Cannot convert " ~ expected.toString()
              ~ " value to a " ~ got.toString());
    }
}

/**
 * This exception is thrown when you attempt to use an empty Value with
 * varargs.
 */
class ValueVoidVarargException : Exception
{
    this()
    {
        super("cannot use Value containing a void with varargs");
    }
}

template returnT(T)
{
    static if( __traits(isStaticArray, T) )
        alias typeof(T.dup) returnT;
    else
        alias T returnT;
}

private struct ValueStorage
{
    union
    {
       /*
        * Contains heap-allocated storage for values which are too large
        * to fit into the Value directly.
        */
        void[] heap;

       /*
        * Used to store arrays directly.  Note that this is NOT an actual
        * array; using a void[] causes the length to change, which screws
        * up the ptr() property.
        *
        * WARNING: this structure MUST match the ABI for arrays for this
        * platform.  AFAIK, all compilers implement arrays this way.
        * There needs to be a case in the unit test to ensure this.
        */
        struct Array
        {
            size_t length;
            const(void)* ptr;
        }
        Array array;

        // Used to simplify dealing with objects.
        Object obj;

        // Used to address storage as an array.
        ubyte[array.sizeof] data;
    }

   /*
    * This is used to set the array structure safely.  We're essentially
    * just ensuring that if a garbage collection happens mid-assign, we
    * don't accidentally mark bits of memory we shouldn't.
    *
    * Of course, the compiler could always re-order the length and ptr
    * assignment.  Oh well.
    */
    void setArray(const(void)* ptr, size_t length)
    {
        array.length = 0;
        array.ptr = ptr;
        array.length = length;
    }
}

struct Value
{
    /*this(T)(ref return scope T other)
    {
        opAssign(other);
    }

    this(ref return scope const Value other) 
    {
        _typeinfo = cast(Rtti)(other._typeinfo);
        _value = cast(ValueStorage)(other._value);
    }*/

    static Value opCall(T)(T value)
    {
        Value v;
        
        static if (__traits(isStaticArray, T))
            v = value.dup;
        else
            v = value;

        return v;
    }

    static Value opCall(immutable(Rtti) type, void* ptr)
    {
        Value v;
        Value.fromPtr(type, ptr, v);
        return v;
    }

    Value opAssign(T)(auto ref T value)
    {
        static if (__traits(isStaticArray, T))
        {
            return (this = value.dup);
        }
        else static if (is(Unqual!T == Value))
        {
            _typeinfo = cast(Rtti) value._typeinfo;
            _value = cast(ValueStorage) value._value;
            return this;
        }
        else
        {
            _typeinfo = cast(Rtti)(getRtti!(StoredType!T));

            static if (isDynamicArray!T)
            {
                _value.setArray(value.ptr, value.length);
            }
            else static if ( is(T == class) || is(T == interface) )
            {
                _value.obj = cast(Object) value;
            }
            else
            {
                /*
                * If the value is small enough to fit in the storage
                * available, do so.  If it isn't, then make a heap copy.
                *
                * Obviously, this pretty clearly breaks value semantics for
                * large values, but without a postblit operator, there's not
                * much we can do.  :(
                */
                if ( T.sizeof <= this._value.data.length )
                {
                    // Copy into storage
                    _value.data[0 .. T.sizeof] =
                        (cast(ubyte*)&value)[0 .. T.sizeof];
                }
                else
                {
                    // Store in heap
                    auto buffer = (cast(ubyte*)&value)[0 .. T.sizeof].dup;
                    _value.heap = cast(void[]) buffer;
                }
            }

            return this;
        }
    }

    @property immutable(Rtti) typeinfo() pure const nothrow
    {
        return cast(immutable(Rtti)) _typeinfo;
    }

   /**
    * Determines whether the Value has an assigned value or not.
    *
    * Returns:
    *  true if the Value does not contain a value, false otherwise.
    */
    @property bool empty() const
    {
        return typeinfo.type == Rtti.Type.Void;
    }

   /**
    * This can be used to retrieve a pointer to the stored value.
    */
    @property void* ptr()
    {
        if (_typeinfo.size <= _value.sizeof)
            return &_value;
        else
            return _value.heap.ptr;
    }

   /**
    * Clears the Value, returning it to an empty state.
    */
    void clear()
    {
        _typeinfo = cast(Rtti) getRtti!void;
        _value = _value.init;
    }

    /**
     * The type a Value records for the copy it took of a T.
     *
     * A Value is a copy, and a qualifier on something through which nothing is
     * reachable does not survive one: the bytes belong to the Value now and
     * nobody else can see them, so there is no promise left to keep.  An
     * immutable float is recorded as a float -- which is what makes
     * `Value(someImmutableFloat)` assignable to a property of type float, the
     * same way the plain assignment is legal in D.
     *
     * Anything that reaches further keeps its qualifier, because what was
     * copied is the handle and the promise is about what lies on the other
     * end: a string stays immutable(char)[], distinct from char[].
     */
    template StoredType(T)
    {
        static if (hasIndirections!T)
            alias StoredType = T;
        else
            alias StoredType = Unqualified!T;
    }

    @property returnT!(S) get(S)() const
    {
        alias returnT!(S) T;

        auto ti = getRtti!T;
        if (!ti.isAssignableFrom(cast(immutable(Rtti))(typeinfo)))
            throw new ValueTypeMismatchException(typeinfo, ti);

        static if ( is(T == U[], U) )
        {
            return (cast(U*) _value.array.ptr) [0.._value.array.length];
        }
        else static if( is(T == class) || is(T == interface) )
        {
            return cast(T) _value.obj;
        }
        else
        {
            static if( T.sizeof <= _value.data.length )
            {
                T result;
                (cast(ubyte*)&result)[0..T.sizeof] = _value.data[0..T.sizeof];
                return result;
            }
            else
            {
                T result;
                (cast(ubyte*)&result)[0..T.sizeof] = (cast(ubyte[])_value.heap)[0..T.sizeof];
                return result;
            }
        }
    }

    /**
    * The following operator overloads are defined for the sake of
    * convenience.  It is important to understand that they do not allow you
    * to use a Variant as both the left-hand and right-hand sides of an
    * expression.  One side of the operator must be a concrete type in order
    * for the Variant to know what code to generate.
    */
    auto opBinary(immutable(char)[] op, T)(T rhs)
    {
        mixin("return get!(T) " ~ op ~ " rhs;");
    }

    auto opBinaryRight(immutable(char)[] op, T)(T lhs)
    {
        mixin("return lhs " ~ op ~ " get!(T);");
    }

    Value opOpAssign(immutable(char)[] op, T)(T value)
    {
        mixin("return (this = get!(T) " ~ op ~ " value);");
    }

   /**
    * Equality.  When compared against a concrete type, the stored value is
    * extracted and compared directly.  When compared against another Value,
    * the comparison is dispatched based on the stored type.
    */
    bool opEquals(R)(auto ref const R rhs) const
    {
        static if (is(Unqual!R == Value))
            return valueEquals(rhs);
        else
            return get!(Unqual!R) == rhs;
    }

   /**
    * Ordering.  Defined for Value-to-Value comparisons between numeric types
    * and for comparisons against a concrete numeric/string type.  Comparing
    * Values of differing types throws ValueTypeMismatchException.
    */
    int opCmp(R)(auto ref const R rhs) const
    {
        static if (is(Unqual!R == Value))
            return valueCompare(rhs);
        else
        {
            auto lhs = get!(Unqual!R);
            return lhs < rhs ? -1 : (lhs > rhs ? 1 : 0);
        }
    }

    hash_t toHash() const
    {
        import core.internal.hash : hashOf;

        final switch (_typeinfo.type)
        {
            case Rtti.Type.Null:
            case Rtti.Type.Void:
                return 0;

            case Rtti.Type.Integer:
            case Rtti.Type.Enum:
            case Rtti.Type.Struct:
            case Rtti.Type.Pointer:
            case Rtti.Type.Function:
                return hashOf(rawBytes());

            case Rtti.Type.Float:
                // Hashed through the same normalisation equality uses, or -0.0
                // and 0.0 would compare equal and hash apart.  Narrowing to
                // double can only make two unequal reals collide, which a hash
                // is allowed to do; it can never split two equal ones.
                return hashOf(cast(double) normalizeFloat(readFloat()));

            case Rtti.Type.StaticArray:
                return hashOf((cast(const(ubyte)[]) _value.heap)[0 .. _typeinfo.size]);

            case Rtti.Type.DynamicArray:
                return hashOf(arrayBytes());

            case Rtti.Type.AssociativeArray:
                return hashOf(rawBytes());

            case Rtti.Type.Class:
                auto o = cast(Object) _value.obj;
                return o ? o.toHash() : 0;
        }
    }
private:
    Rtti _typeinfo = cast(Rtti)(getRtti!void);
    ValueStorage _value;

   /*
    * Returns a view over the raw storage bytes of a directly-stored value
    * (small values live inline; larger ones live on the heap).
    */
    const(ubyte)[] rawBytes() const return
    {
        immutable sz = _typeinfo.size;
        if (sz <= _value.data.length)
            return _value.data[0 .. sz];
        return (cast(const(ubyte)[]) _value.heap)[0 .. sz];
    }

   /*
    * Returns a view over the element bytes of a stored dynamic array.
    */
    const(ubyte)[] arrayBytes() const
    {
        auto at = cast(immutable(RttiArrayType)) typeinfo;
        immutable byteLen = _value.array.length * at.elementType.size;
        return (cast(const(ubyte)*) _value.array.ptr)[0 .. byteLen];
    }

    long readSigned() const
    {
        auto p = rawBytes().ptr;
        switch (_typeinfo.size)
        {
            case 1:  return *cast(const(byte)*) p;
            case 2:  return *cast(const(short)*) p;
            case 4:  return *cast(const(int)*) p;
            case 8:  return *cast(const(long)*) p;
            default: return 0;
        }
    }

    ulong readUnsigned() const
    {
        auto p = rawBytes().ptr;
        switch (_typeinfo.size)
        {
            case 1:  return *cast(const(ubyte)*) p;
            case 2:  return *cast(const(ushort)*) p;
            case 4:  return *cast(const(uint)*) p;
            case 8:  return *cast(const(ulong)*) p;
            default: return 0;
        }
    }

   /*
    * Read as real, which holds a float, a double and a real without losing
    * anything.  Reading a real as a double used to round it, so two values
    * that differ past the 53rd bit compared equal.
    */
    real readFloat() const
    {
        auto p = rawBytes().ptr;
        switch (_typeinfo.size)
        {
            case 4:  return *cast(const(float)*) p;
            case 8:  return *cast(const(double)*) p;
            default: return *cast(const(real)*) p;
        }
    }

   /*
    * Float comparison, answered the same way by equality, ordering and
    * hashing.  Two rules depart from IEEE, both for the same reason: a Value
    * is compared to decide whether something changed and to find it again in
    * a container, and neither survives a value that is not equal to itself.
    *
    *   - NaN equals NaN.  Otherwise a property set to NaN would report a
    *     change on every assignment for as long as the program ran, and a
    *     Value could be put into a container and never found.
    *   - -0.0 equals 0.0, which is what IEEE says and what the bytes deny.
    *
    * .NET settled on the same two for Equals and CompareTo, and for the same
    * reasons.  Comparing a Value against a bare float still goes through that
    * float's own ==, which is IEEE: that asks a different question, about a
    * number rather than about a stored value.
    */
    static bool floatEquals(real a, real b)
    {
        // `a != a` is the NaN test, without reaching for std.math.
        return a == b || (a != a && b != b);
    }

    static int floatCompare(real a, real b)
    {
        if (a < b)
            return -1;
        if (a > b)
            return 1;
        if (a == b)
            return 0;   // including -0.0 against 0.0

        // What is left involves a NaN.  Placing every NaN before every number
        // is arbitrary, but it is total, which is what a sorted container
        // needs -- and two NaNs come out equal, as floatEquals says they are.
        immutable aIsNaN = a != a;
        immutable bIsNaN = b != b;

        if (aIsNaN && bIsNaN)
            return 0;

        return aIsNaN ? -1 : 1;
    }

    static real normalizeFloat(real v)
    {
        if (v != v)
            return real.nan;    // every NaN hashes as one

        return v == 0 ? 0.0L : v;   // and -0.0 hashes as 0.0
    }

   /*
    * Type-dispatched equality between two Values.
    */
    bool valueEquals(ref const Value other) const
    {
        if (!typeinfo.isSameType(other.typeinfo))
            return false;

        final switch (_typeinfo.type)
        {
            case Rtti.Type.Null:
            case Rtti.Type.Void:
                return true;

            case Rtti.Type.Integer:
            case Rtti.Type.Enum:
            case Rtti.Type.Struct:
            case Rtti.Type.Pointer:
            case Rtti.Type.Function:
                return rawBytes() == other.rawBytes();

            case Rtti.Type.Float:
                return floatEquals(readFloat(), other.readFloat());

            case Rtti.Type.StaticArray:
                return (cast(const(ubyte)[]) _value.heap)[0 .. _typeinfo.size]
                    == (cast(const(ubyte)[]) other._value.heap)[0 .. other._typeinfo.size];

            case Rtti.Type.DynamicArray:
                return arrayBytes() == other.arrayBytes();

            case Rtti.Type.AssociativeArray:
                // TODO: Implement structural (order-independent) equality for
                // associative arrays.  Until then an AA-typed Value compares
                // unequal even to itself, so it must not be used as an
                // associative-array key.  valueCompare and toHash share this
                // limitation.
                return false;

            case Rtti.Type.Class:
                return cast(const(void)*) _value.obj is cast(const(void)*) other._value.obj;
        }
    }

   /*
    * Type-dispatched ordering between two Values.  Only numeric types are
    * ordered; other same-typed values report equal-or-unordered.
    */
    int valueCompare(ref const Value other) const
    {
        if (!typeinfo.isSameType(other.typeinfo))
            throw new ValueTypeMismatchException(typeinfo, other.typeinfo);

        switch (_typeinfo.type)
        {
            case Rtti.Type.Integer:
                if ((cast(immutable(RttiIntegerType)) typeinfo).signed)
                {
                    immutable a = readSigned(), b = other.readSigned();
                    return a < b ? -1 : (a > b ? 1 : 0);
                }
                else
                {
                    immutable a = readUnsigned(), b = other.readUnsigned();
                    return a < b ? -1 : (a > b ? 1 : 0);
                }

            case Rtti.Type.Float:
                return floatCompare(readFloat(), other.readFloat());

            default:
                return valueEquals(other) ? 0 : -1;
        }
    }

   /*
    * Creates a Value using a given TypeInfo and a void*.  Returns the
    * given pointer adjusted for the next vararg.
    */
    static void* fromPtr(immutable(Rtti) typeinfo, void* ptr, out Value r)
    {
       /*
        * This function basically duplicates the functionality of
        * opAssign, except that we can't generate code based on the
        * type of the data we're storing.
        */

        if ( typeinfo.type == Rtti.Type.Null ||
			 typeinfo.type == Rtti.Type.Void )
		{
            throw new ValueVoidVarargException;
		}

        r._typeinfo = cast(Rtti)(typeinfo);

        if ( typeinfo.type == Rtti.Type.StaticArray )
        {
           /*
            * Static arrays are passed by-value; for example, if type is
            * typeid(int[4]), then ptr is a pointer to 16 bytes of memory
            * (four 32-bit integers).
            *
            * It's possible that the memory being pointed to is on the
            * stack, so we need to copy it before storing it.  type.tsize
            * tells us exactly how many bytes we need to copy.
            *
            * Sadly, we can't directly construct the dynamic array version
            * of type.  We'll store the static array type and cope with it
            * in isImplicitly(S) and get(S).
            */
            r._value.heap = ptr[0 .. typeinfo.size].dup;
        }
        else
        {
            if ( typeinfo.type == Rtti.Type.Class )
            {
               /*
                * We have to call into the core runtime to turn this pointer
                * into an actual Object reference.
                */
                r._value.obj = cast(Object)(*cast(void**)ptr);
            }
            else
            {
                if ( typeinfo.size <= this._value.data.length )
                {
                    // Copy into storage
                    r._value.data[0 .. typeinfo.size] =
                        (cast(ubyte*)ptr)[0 .. typeinfo.size];
                }
                else
                {
                    // Store in heap
                    auto buffer = (cast(ubyte*)ptr)[0 .. typeinfo.size].dup;
                    r._value.heap = cast(void[]) buffer;
                }
            }
        }

        // Compute the "advanced" pointer.
        return ptr + ( (typeinfo.size + size_t.sizeof-1) & ~(size_t.sizeof-1) );
    }
}

/*
 * Compiler ABI tests
 */
unittest {
    {
        int[2] a;
        void[] b = a;
        int[]  c = cast(int[]) b;
        assert( b.length == 2*int.sizeof );
        assert( c.length == a.length );
    }
    {
        struct A { size_t l; void* p; }
        const(char)[] b = "123";
        A a = *cast(A*)(&b);

        assert( a.l == b.length );
        assert( a.p == b.ptr );
    }
}

unittest
{
    Value v;
    assert( v.typeinfo == getRtti!void, v.typeinfo.toString() );
    assert( v.empty, v.typeinfo.toString() );

    // Test basic integer storage and implicit casting support
    v = 42;
    assert( v.typeinfo == getRtti!int, v.typeinfo.toString() );
    assert( v.get!(int) == 42 );
    assert( v.get!(long) == 42L );
    assert( v.get!(ulong) == 42uL );

    // Test clearing
    v.clear();
    assert( v.typeinfo == getRtti!void, v.typeinfo.toString() );
    assert( v.empty, v.typeinfo.toString() );

    // Test strings
    v = "Hello, World!"c;
    assert( v.typeinfo == getRtti!(immutable(char)[]), v.typeinfo.toString() );
    assert( v.get!(immutable(char)[]) == "Hello, World!" );

    // Test array storage
    v = [1,2,3,4,5];
    assert( v.typeinfo == getRtti!(int[]), v.typeinfo.toString() );
    assert( v.get!(int[]) == [1,2,3,4,5] );

    // Make sure arrays are correctly stored so that .ptr works.
    {
        int[] a = [1,2,3,4,5];
        v = a;
        auto b = *cast(int[]*)(v.ptr);

        assert( a.ptr == b.ptr );
        assert( a.length == b.length );
    }

    // Test pointer storage
    v = &v;
    assert( v.typeinfo == getRtti!(Value*), v.typeinfo.toString() );
    assert( v.get!(Value*) == &v );

    // Test object storage
    {
        scope o = new Object;
        v = o;
        assert( v.typeinfo == getRtti!(Object), v.typeinfo.toString() );
        assert( v.get!(Object) is o );
    }

    // Test interface support
    {
        interface A {}
        interface B : A {}
        class C : B {}
        class D : C {}

        D a = new D;
        Value v2 = a;
        B b = v2.get!(B);
        C c = v2.get!(C);
        D d = v2.get!(D);
    }

    // Test doubles and implicit casting
    v = 3.1413;
    assert( v.typeinfo == getRtti!(double), v.typeinfo.toString() );
    assert( v.get!(double) == 3.1413 );

    // Test storage transitivity
    auto u = Value(v);
    assert( u.typeinfo == getRtti!(double), u.typeinfo.toString() );
    assert( u.get!(double) == 3.1413 );

    // Test operators
    v = 38;
    assert( v + 4 == 42 );
    assert( 4 + v == 42 );
    assert( v - 4 == 34 );
    assert( 4 - v == -34 );
    assert( v * 2 == 76 );
    assert( 2 * v == 76 );
    assert( v / 2 == 19 );
    assert( 2 / v == 0 );
    assert( v % 2 == 0 );
    assert( 2 % v == 2 );
    assert( (v & 6) == 6 );
    assert( (6 & v) == 6 );
    assert( (v | 9) == 47 );
    assert( (9 | v) == 47 );
    assert( (v ^ 5) == 35 );
    assert( (5 ^ v) == 35 );
    assert( v << 1 == 76 );
    assert( 1 << Value(2) == 4 );
    assert( v >> 1 == 19 );
    assert( 4 >> Value(2) == 1 );

    assert( Value("abc") ~ "def" == "abcdef" );
    assert( "abc" ~ Value("def") == "abcdef" );

    // Test op= operators
    v = 38; v += 4; assert( v == 42 );
    v = 38; v -= 4; assert( v == 34 );
    v = 38; v *= 2; assert( v == 76 );
    v = 38; v /= 2; assert( v == 19 );
    v = 38; v %= 2; assert( v == 0 );
    v = 38; v &= 6; assert( v == 6 );
    v = 38; v |= 9; assert( v == 47 );
    v = 38; v ^= 5; assert( v == 35 );
    v = 38; v <<= 1; assert( v == 76 );
    v = 38; v >>= 1; assert( v == 19 );

    v = "abc"; v ~= "def"; assert( v == "abcdef" );

    // Test comparison
    assert( Value(0) < Value(42) );
    assert( Value(42) > Value(0) );
    assert( Value(21) == Value(21) );
    assert( Value(0) != Value(42) );
    assert( Value("bar") == Value("bar") );
    assert( Value("foo") != Value("bar") );

    // Test variants as AA keys
    {
        auto v1 = Value(42);
        auto v2 = Value("foo");
        auto v3 = Value(3.5);

        int[Value] hash;
        hash[v1] = 0;
        hash[v2] = 1;
        hash[v3] = 2;

        assert( hash[v1] == 0 );
        assert( hash[v2] == 1 );
        assert( hash[v3] == 2 );
    }

    // Test AA storage
    {
        int[char[]] hash;
        hash["a"] = 1;
        hash["b"] = 2;
        hash["c"] = 3;
        Value vhash = hash;

        assert( vhash.get!(int[char[]])["a"] == 1 );
        assert( vhash.get!(int[char[]])["b"] == 2 );
        assert( vhash.get!(int[char[]])["c"] == 3 );
    }

    // toHash is type-sensitive and consistent with equality.
    assert( Value(42).toHash() == Value(42).toHash() );
    assert( Value(42).toHash() != Value(43).toHash() );
    assert( Value(42).toHash() != Value("42").toHash() );

    // Equal-but-distinct array instances hash equally (content-based hashing),
    // which is what makes Value usable as an associative-array key.
    {
        auto s1 = "hello".idup;
        auto s2 = "hello".idup;
        assert( s1.ptr !is s2.ptr );
        assert( Value(s1) == Value(s2) );
        assert( Value(s1).toHash() == Value(s2).toHash() );
    }
}

unittest
{
    static class K {}

    // Regression: this goes through opAssign!(const K) -> getRtti!(const K),
    // which used to fail to compile inside the class-RTTI registration.
    const K k = new K;
    Value v = k;
    assert(v.get!(const K) is k);
}

unittest
{
    // A Value is a copy, and a qualifier on something through which nothing is
    // reachable does not survive one -- the bytes belong to the Value now, and
    // nobody is left to be promised anything about them.
    immutable float pinned = 12.5f;
    auto v = Value(pinned);

    assert(v.typeinfo == getRtti!float);
    assert(v.get!float == 12.5f);

    // Which is what lets the property system store it: the same question it
    // asks before writing a value into a property of type float.
    assert(getRtti!float.isAssignableFrom(cast(immutable(Rtti)) v.typeinfo));

    static struct Plain { float x; float y; }
    immutable Plain frozen = Plain(1, 2);
    assert(Value(frozen).typeinfo == getRtti!Plain);

    const int counted = 7;
    assert(Value(counted).typeinfo == getRtti!int);

    // What reaches further keeps its qualifier: what was copied is the handle,
    // and the promise is about the other end of it.
    auto text = Value("cherry");
    assert(text.typeinfo == getRtti!(immutable(char)[]));
    assert(text.typeinfo != getRtti!(char[]), "string is not char[], and must not become it");

    immutable(int)[] frozenItems = [1, 2, 3];
    assert(Value(frozenItems).typeinfo == getRtti!(immutable(int)[]));
}

unittest
{
    // Equality, ordering and hashing answer the same way about floats, which
    // IEEE on its own does not give: it makes NaN unequal to itself, and the
    // bytes make -0.0 unequal to 0.0.
    auto nan1 = Value(double.nan);
    auto nan2 = Value(double.nan);
    auto zero = Value(0.0);
    auto negZero = Value(-0.0);
    auto one = Value(1.0);

    assert(nan1 == nan2, "a value must equal itself, or it can never be found again");
    assert(nan1.opCmp(nan2) == 0);
    assert(nan1.toHash() == nan2.toHash());

    assert(zero == negZero, "one number, whatever the bytes say");
    assert(zero.opCmp(negZero) == 0);
    assert(zero.toHash() == negZero.toHash(), "equal values, equal hashes");

    // NaN is ordered arbitrarily but totally, so a sorted container has
    // somewhere to put it -- and 0 no longer means "equal or unordered".
    assert(nan1.opCmp(one) < 0);
    assert(one.opCmp(nan1) > 0);

    // Ordinary ordering is untouched.
    assert(one.opCmp(Value(2.0)) < 0);
    assert(Value(2.0).opCmp(one) > 0);
    assert(one.opCmp(Value(1.0)) == 0);
    assert(one == Value(1.0));
    assert(one != Value(2.0));

    // A real is compared at its own width.  Both of these round to the same
    // double, and ordering read them as one -- so it called them equal while
    // equality, which went by the bytes, did not.
    assert(Value(1.0L + real.epsilon) != Value(1.0L));
    assert(Value(1.0L + real.epsilon).opCmp(Value(1.0L)) > 0);
    assert(Value(1.0L) == Value(1.0L));
    assert(Value(1.0L).opCmp(Value(1.0L)) == 0);
}
