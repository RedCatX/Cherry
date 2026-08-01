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

/**
 * A list of handlers invoked as a single delegate.
 *
 * Not internally synchronized: when a multicast is shared between threads,
 * the owner supplies the lock.  Handlers must be invoked outside that lock
 * -- holding it across handler calls invites deadlock -- so take a snapshot
 * first:
 * ---
 * Multicast!D snapshot;
 * synchronized (mutex)
 *     snapshot = _handlers.dup;
 * snapshot(args);
 * ---
 * Mutating the original afterwards never disturbs the snapshot: add and
 * remove replace the array rather than rewriting it in place.
 */
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

	/**
	 * Removes every registration of the handler.
	 *
	 * Always builds a fresh array instead of compacting in place, so any
	 * copy taken earlier -- a snapshot waiting to be invoked, or the list an
	 * in-progress invocation is walking -- keeps seeing what it captured.
	 * The allocation falls on the (rare) removal, never on invocation.
	 */
	ref auto remove(const D d) nothrow pure @trusted
	{
		// The copy bit shares storage with the array length, so clear it
		// before the length is read.  It stays clear: the new array is ours.
		_accessMask &= ~needsCopyBit;
		_delegates = _delegates.dup.remove!(a => a == d);

		return this;
	}

	/**
	 * Returns an independent copy of the handler list -- the snapshot half
	 * of the "copy under the lock, invoke outside it" pattern described on
	 * the struct.
	 */
	Multicast!D dup() const nothrow pure @trusted
	{
		// Mask the copy bit out rather than reading _delegates.length, which
		// shares storage with it.
		immutable count = _accessMask & ~needsCopyBit;

		Multicast!D result;
		if (count > 0)
			result._delegates = (cast(D*) _delegates.ptr)[0 .. count].dup;

		return result;
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
		return (_delegates.length & ~needsCopyBit) != 0;
	}

	ReturnType!D _invokeImpl(Parameters!D params) const @trusted
	{
		const copyBit = (_accessMask & needsCopyBit) != 0;
		cast() _accessMask &= ~needsCopyBit;
		const ptr = _delegates.ptr;
		scope (exit)
			if (copyBit && _delegates.ptr == ptr)
				cast() _accessMask |= needsCopyBit;

		// Read the list once: a handler may subscribe or unsubscribe while the
		// event is being delivered, which replaces the field mid-iteration.
		auto handlers = _delegates;

		// Raising an event nobody listens to is a no-op rather than an error.
		// The alternative makes every call site guard with empty, and forgetting
		// the guard costs a crash instead of nothing happening.  A handler type
		// with a return value yields that type's default.
		if (handlers.length == 0)
		{
			static if (is(ReturnType!D == void))
				return;
			else
				return ReturnType!D.init;
		}

		foreach (D d; handlers[0 .. $ - 1])
			d(forward!params);
		return handlers[$ - 1](forward!params);
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
@safe unittest
{
    alias Del = void function() @safe;
    static void f() @safe {}

    // The postblit sets the copy-on-write bit inside the length/accessMask
    // union; empty() and opCast!bool must both mask it out.
    Multicast!Del m;
    auto emptyCopy = m;
    assert(emptyCopy.empty);
    assert(!emptyCopy);

    m ~= &f;
    auto fullCopy = m;
    assert(!fullCopy.empty);
    assert(cast(bool) fullCopy);
}

/**
 * Marks a public event accessor.  Collected into RttiClassType.eventNames
 * when the class RTTI is built, so tooling and the future JUICE runtime can
 * discover a class's events:
 * ---
 * private Multicast!(void delegate(Timer)) _onTick;
 *
 * @event @property EventAccessor!(void delegate(Timer)) onTick()
 * {
 *     return eventAccessor(&_onTick);
 * }
 * ---
 */
@safe unittest
{
	// A snapshot keeps what it captured when the original is mutated
	// afterwards, which is what makes "copy under the lock, invoke outside
	// it" safe for a multicast shared between threads.
	alias Del = void function(ref int[]) @safe;

	static void f1(ref int[] log) @safe { log ~= 1; }
	static void f2(ref int[] log) @safe { log ~= 2; }
	static void f3(ref int[] log) @safe { log ~= 3; }

	Multicast!Del original;
	original ~= &f1;
	original ~= &f2;
	original ~= &f3;

	auto snapshot = original.dup;
	original.remove(&f2);

	int[] fromSnapshot;
	snapshot(fromSnapshot);
	assert(fromSnapshot == [1, 2, 3]);

	int[] fromOriginal;
	original(fromOriginal);
	assert(fromOriginal == [1, 3]);

	// A plain struct copy carries the same guarantee, in both directions.
	Multicast!Del other;
	other ~= &f1;
	other ~= &f2;

	auto plainCopy = other;
	other.remove(&f1);

	int[] fromCopy;
	plainCopy(fromCopy);
	assert(fromCopy == [1, 2]);

	// dup of an empty multicast is empty and independent.
	Multicast!Del none;
	auto noneCopy = none.dup;
	assert(noneCopy.empty);
	none ~= &f1;
	assert(noneCopy.empty);
}

@safe unittest
{
	// A handler may unsubscribe another one while the event is being
	// delivered: the invocation walks the list captured on entry, and the
	// change takes effect from the next raise.
	alias Del = void function(ref int[]) @safe;

	static Multicast!Del target;

	static void first(ref int[] log) @safe { log ~= 1; }
	static void third(ref int[] log) @safe { log ~= 3; }
	static void unsubscriber(ref int[] log) @safe
	{
		log ~= 2;
		target.remove(&third);
	}

	target ~= &first;
	target ~= &unsubscriber;
	target ~= &third;

	int[] firstRaise;
	target(firstRaise);
	assert(firstRaise == [1, 2, 3]);

	int[] secondRaise;
	target(secondRaise);
	assert(secondRaise == [1, 2]);
}

@safe unittest
{
	// Raising an event with no subscribers does nothing, so a raise site
	// needs no `empty` guard.
	alias Del = void function(ref int[]) @safe;

	static void f1(ref int[] log) @safe { log ~= 1; }

	Multicast!Del noSubscribers;
	int[] log;
	noSubscribers(log);
	assert(log.length == 0);

	// Still empty after every handler has been removed again.
	Multicast!Del drained;
	drained ~= &f1;
	drained.remove(&f1);
	drained(log);
	assert(log.length == 0);

	// A handler type that returns a value yields that type's default.
	alias IntDel = int function() @safe;
	Multicast!IntDel noResult;
	assert(noResult() == 0);
}

// The event accessor below stores and invokes handler-wrapping delegates
// whose safety cannot be verified here (a routed event's add/remove touch
// @system Element methods), so this section opts out of the module @safe.
@system:

struct event
{
}

/**
 * Subscription-only view of an event: exposes `~=` and `-=` over a pair of
 * add/remove operations, hiding how handlers are stored.  A single type
 * serves both event tiers -- plain (Multicast-backed) and routed -- because
 * only those two operations differ, and they are supplied at construction
 * (the C# add/remove model).  Raising the event and clearing the handler
 * list stay with the owner.
 *
 * H is the handler type (a delegate or function pointer).  Build one with a
 * factory: eventAccessor(&field) for a plain event, or
 * cherry.ui.event.routedAccessor(element, event) for a routed one; use the
 * constructor directly for custom add/remove logic.
 */
struct EventAccessor(H)
{
    this(void delegate(H) add, void delegate(H) remove) pure nothrow @nogc
    in {
        assert(add !is null && remove !is null);
    }
    do {
        _add = add;
        _remove = remove;
    }

    /// Subscribes a handler.
    void opOpAssign(string op : "~")(H handler)
    {
        _add(handler);
    }

    /// Unsubscribes a handler.
    void opOpAssign(string op : "-")(H handler)
    {
        _remove(handler);
    }

private:
    void delegate(H) _add;
    void delegate(H) _remove;
}

/**
 * Builds an EventAccessor over a private Multicast field -- the common case
 * for a plain event:
 * ---
 * @event @property auto onTick() { return eventAccessor(&_onTick); }
 * ---
 */
EventAccessor!H eventAccessor(H)(Multicast!H* field)
in {
    assert(field !is null);
}
do {
    return EventAccessor!H((H h) { field.add(h); }, (H h) { field.remove(h); });
}

unittest
{
    // EventAccessor over a private Multicast: subscribers see only ~= / -=,
    // the owner raises through the field.
    static class Counter
    {
        private Multicast!(void delegate()) _onChanged;

        @event @property auto onChanged()
        {
            return eventAccessor(&_onChanged);
        }

        void bump()
        {
            _onChanged();
        }
    }

    int notified;
    auto counter = new Counter;
    auto handler = delegate() { notified++; };

    counter.onChanged ~= handler;
    counter.bump();
    assert(notified == 1);

    counter.onChanged ~= handler;   // registered twice
    counter.bump();
    assert(notified == 3);

    counter.onChanged -= handler;   // removes every registration of handler
    counter.bump();
    assert(notified == 3);
}
