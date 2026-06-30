module cherry.core.trait;

/**
* Strips the qualifiers from a type
*/

template BaseTypeOf( T )
{
    static if (is(T S : shared(S)))
        alias S BaseTypeOf;
    else static if (is(T S : shared(const(S))))
        alias S BaseTypeOf;
    else static if (is(T S : const(S)))
        alias S BaseTypeOf;
    else
        alias T BaseTypeOf;
}

/**
* Evaluates to true if T is char[], wchar[], or dchar[].
*/
template isStringType( T )
{
    const bool isStringType = is( T : const(char)[] )  ||
                              is( T : const(wchar)[] ) ||
                              is( T : const(dchar)[] );
}

/**
* Evaluates to true if T is char, wchar, or dchar.
*/
template isCharType( T )
{
    const bool isCharType = is( BaseTypeOf!(T) == char )  ||
                            is( BaseTypeOf!(T) == wchar ) ||
                            is( BaseTypeOf!(T) == dchar );
}

/**
* Evaluates to true if T is a signed integer type.
*/
template isSignedIntegerType( T )
{
    const bool isSignedIntegerType = is( BaseTypeOf!(T) == byte )  ||
                                     is( BaseTypeOf!(T) == short ) ||
                                     is( BaseTypeOf!(T) == int )   ||
                                     is( BaseTypeOf!(T) == long );
}


/**
* Evaluates to true if T is an unsigned integer type.
*/
template isUnsignedIntegerType( T )
{
    const bool isUnsignedIntegerType = is( BaseTypeOf!(T) == ubyte )  ||
                                       is( BaseTypeOf!(T) == ushort ) ||
                                       is( BaseTypeOf!(T) == uint )   ||
                                       is( BaseTypeOf!(T) == ulong );
}


/**
* Evaluates to true if T is a signed or unsigned integer type.
*/
template isIntegerType( T )
{
    const bool isIntegerType = isSignedIntegerType!(T) ||
                               isUnsignedIntegerType!(T);
}


/**
* Evaluates to true if T is a real floating-point type.
*/
template isRealType( T )
{
    const bool isRealType = is( BaseTypeOf!(T) == float )  ||
                            is( BaseTypeOf!(T) == double ) ||
                            is( BaseTypeOf!(T) == real );
}


/**
* Evaluates to true if T is a complex floating-point type.
*/
template isComplexType( T )
{
    const bool isComplexType = is( BaseTypeOf!(T) == cfloat )  ||
                               is( BaseTypeOf!(T) == cdouble ) ||
                               is( BaseTypeOf!(T) == creal );
}


/**
* Evaluates to true if T is an imaginary floating-point type.
*/
template isImaginaryType( T )
{
    const bool isImaginaryType = is( T == ifloat )  ||
                                 is( T == idouble ) ||
                                 is( T == ireal );
}


/**
* Evaluates to true if T is any floating-point type: real, complex, or
* imaginary.
*/
template isFloatingPointType( T )
{
    const bool isFloatingPointType = isRealType!(T)    ||
                                     isComplexType!(T) ||
                                     isImaginaryType!(T);
}

/// true if T is an atomic type
template isAtomicType(T)
{
    static if ( is( T == bool )
           || is( T == char )
           || is( T == wchar )
           || is( T == dchar )
           || is( T == byte )
           || is( T == short )
           || is( T == int )
           || is( T == long )
           || is( T == ubyte )
           || is( T == ushort )
           || is( T == uint )
           || is( T == ulong )
           || is( T == float )
           || is( T == double )
           || is( T == real )
           || is( T == ifloat )
           || is( T == idouble )
           || is( T == ireal ) )
    {
        const isAtomicType = true;
    }
    else
    {
        const isAtomicType = false;
    }
}

/**
* Evaluates to true if T is a pointer type.
*/
template isPointerType(T)
{
    const isPointerType = false;
}

template isPointerType(T : T*)
{
    const isPointerType = true;
}