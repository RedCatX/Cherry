module cherry.core.multicast;

import std.algorithm : remove;
import std.functional : forward;
import std.traits : isDelegate, isFunctionPointer,
                    FunctionAttribute, functionAttributes,
                    functionLinkage, Parameters, ReturnType,
                    SetFunctionAttributes, Unqual;

@safe:

static if (is(size_t == ulong))
    private enum needsCopyBit = 1UL << 63UL;
else
    private enum needsCopyBit = cast(size_t)(1 << (8 * size_t.sizeof - 1));

struct Multicast(D)
if (isDelegate!D || isFunctionPointer!D)
{
    this(typeof(null)) nothrow pure @nogc immutable
	{
	}

    this(D d) nothrow pure immutable @trusted
    {
        _delegates = [d];
    }

    this(immutable(D)[] delegates) nothrow pure @nogc immutable @trusted
	{
		_delegates = delegates;
		(cast()this)._accessMask |= needsCopyBit;
	}

    this(D[] delegates) nothrow pure @nogc @trusted
	{
		_delegates = delegates;
	}

    this(this)
	{
		_accessMask |= needsCopyBit;
	}

    @property inout(D[]) delegates() inout nothrow pure @nogc @trusted
	{
		const mask = _accessMask;
		cast() _accessMask &= ~needsCopyBit;
		inout(D[]) ret = _delegates;
		cast() _accessMask = mask;
		return ret;
	}

	@property ref auto delegates(D[] dls) nothrow pure @nogc @trusted
	{
		_accessMask &= ~needsCopyBit;
		_delegates = dls;
		return this;
	}

	@property bool empty() pure const nothrow @trusted
    {
		return (_delegates.length & ~needsCopyBit) == 0;
    }

	ref auto add(const D[] dls) nothrow pure @trusted
	{
		const copyBit = (_accessMask & needsCopyBit) != 0;
		_accessMask &= ~needsCopyBit;
		const ptr = _delegates.ptr;
		scope (exit)
			if (copyBit && _delegates.ptr == ptr)
				_accessMask |= needsCopyBit;
		_delegates ~= dls;
		return this;
	}

	ref auto add(const Multicast!D other) nothrow pure @trusted
	{
		const copyBit = (_accessMask & needsCopyBit) != 0;
		_accessMask &= ~needsCopyBit;
		const ptr = _delegates.ptr;
		scope (exit)
			if (copyBit && _delegates.ptr == ptr)
				_accessMask |= needsCopyBit;
		_delegates ~= other.delegates;
		return this;
	}

	ref auto add(const D d) nothrow pure @trusted
	{
		const copyBit = (_accessMask & needsCopyBit) != 0;
		_accessMask &= ~needsCopyBit;
		const ptr = _delegates.ptr;
		scope (exit)
			if (copyBit && _delegates.ptr == ptr)
				_accessMask |= needsCopyBit;
		_delegates ~= d;
		return this;
	}

	ref auto remove(const D d) nothrow pure @trusted
	{
		if ((_accessMask & needsCopyBit) != 0)
		{
			_accessMask &= ~needsCopyBit;
			_delegates = _delegates.dup.remove!(a => a == d);
		}
		else
		{
			_delegates = _delegates.remove!(a => a == d);
		}

		return this;
	}

	ref auto opAssign(const D d) nothrow pure
	{
		delegates = [d];
		return this;
	}

	ref auto opAssign(D[] dls) nothrow pure @nogc
	{
		delegates = dls;
		return this;
	}

	ref auto opAssign(typeof(null)) nothrow pure @nogc @trusted
	{
		_accessMask &= ~needsCopyBit;
		_delegates = null;
		_accessMask = 0;
		return this;
	}

	alias opOpAssign(string op : "~") = add;

	auto opBinary(string op, T)(const T rhs) const
	{
		Unqual!(typeof(this)) copy;
		copy.delegates = delegates.dup;
		copy.opOpAssign!op(rhs);
		return copy;
	}

	bool opCast(T : bool)() const nothrow pure @nogc @trusted
	{
		return _delegates.length > 0;
	}

	ReturnType!D _invokeImpl(Parameters!D params) const @trusted
	{
		const copyBit = (_accessMask & needsCopyBit) != 0;
		cast() _accessMask &= ~needsCopyBit;
		scope (exit)
			if (copyBit)
				cast() _accessMask |= needsCopyBit;

		assert(_delegates.length > 0, "Tried to call unassigned multicast delegate");

		foreach (D d; _delegates[0 .. $ - 1])
			d(forward!params);
		return _delegates[$ - 1](forward!params);
	}

	auto _invokePtr() const nothrow pure @nogc @trusted
	{
		return cast(SetFunctionAttributes!(typeof(&_invokeImpl),
                                           "D", functionAttributes!D)) &_invokeImpl;
	}

	alias toDelegate = _invokePtr;
	alias toDelegate this;

    private union 
    {
        D[] _delegates;
        size_t _accessMask;
    }
}

@system unittest
{
	int modify1(ref string[] stack)
	{
		stack ~= "1";
		return cast(int) stack.length;
	}

	int modify2(ref string[] stack)
	{
		stack ~= "2";
		return 9001;
	}

	string[] stack;

	// del is like a delegate now
	Multicast!(int delegate(ref string[])) del = &modify1;
	assert(del(stack) == 1);
	assert(stack == ["1"]);

	stack = null;
	del ~= &modify2;
	assert(del(stack) == 9001);
	assert(stack == ["1", "2"]);

	void someMethod(int delegate(ref string[]) fn)
	{
	}

	someMethod(del);
	someMethod(del);
}

@safe unittest
{
	import std.exception;
	import core.exception;

	string[] calls;

	void call1()
	{
		calls ~= "1";
	}

	void call2()
	{
		calls ~= "2";
	}

	Multicast!(void delegate() @safe) del;

	del = &call1;
	del();
	assert(calls == ["1"]);

	calls = null;
	del();
	assert(calls == ["1"]);

	calls = null;
	del();
	del();
	assert(calls == ["1", "1"]);

	calls = null;
	del ~= &call1;
	del();
	assert(calls == ["1", "1"]);

	calls = null;
	del ~= &call2;
	del();
	assert(calls == ["1", "1", "2"]);
}

@safe unittest
{
	alias Del = int delegate(long) @safe nothrow @nogc pure;

	int fun1(long n) @safe nothrow @nogc pure
	{
		return cast(int)(n - 1);
	}

	int fun2(long n) @safe nothrow @nogc pure
	{
		return cast(int)(n - 2);
	}

	Multicast!Del foo = [&fun1, &fun2];

	assert((() nothrow @nogc pure => foo(8))() == 6);

	void someMethod(Del fn)
	{
		fn(4);
	}

	someMethod(foo);
}

@safe unittest
{
	import std.exception;

	alias Del = void delegate() @safe;

	int[] stack;

	void f1()
	{
		stack ~= 1;
	}

	void f2()
	{
		stack ~= 2;
		throw new Exception("something occurred");
	}

	void f3()
	{
		stack ~= 3;
	}

	Multicast!Del something;
	something ~= &f1;
	something ~= &f2;
	something ~= &f3;

	assertThrown(something());
	assert(stack == [1, 2]);
}

@safe unittest
{
	alias Del = void function(ref int[]) @safe;

	int[] stack;

	static void f1(ref int[] stack) @safe
	{
		stack ~= 1;
	}

	static void f2(ref int[] stack) @safe
	{
		stack ~= 2;
	}

	Multicast!Del something;
	something ~= &f1;
	something ~= &f2;

	something(stack);
	assert(stack == [1, 2]);

	stack = null;
	(something ~ &f2)(stack);
	assert(stack == [1, 2, 2]);

	stack = null;
	const Multicast!Del constSomething = &f1;

	constSomething(stack);
	assert(stack == [1]);

	stack = null;
	(constSomething ~ &f2)(stack);
	assert(stack == [1, 2]);

	stack = null;
	immutable Multicast!Del immutableSomething = &f1;
	immutable Multicast!Del immutableSomething2 = [
		&f1, &f2
    ];

	immutableSomething(stack);
	assert(stack == [1]);

	stack = null;
	(immutableSomething ~ &f2)(stack);
	assert(stack == [1, 2]);
}

@safe unittest
{
	alias Del = void function(ref int[]) @safe;

	int[] stack;

	static void f1(ref int[] stack) @safe
	{
		stack ~= 1;
	}

	static void f2(ref int[] stack) @safe
	{
		stack ~= 2;
	}

	Multicast!Del something;
	something ~= &f1;
	something ~= &f2;

	Multicast!Del copy = something;
	copy.remove(&f1);

	something(stack);
	assert(stack == [1, 2]);

	stack = null;
	copy(stack);
	assert(stack == [2]);
}