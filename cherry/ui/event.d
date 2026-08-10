module cherry.ui.event;

/*
 * This module and cherry.ui.element import each other -- an element routes
 * events, and a routed event's accessor and args name the element.  Since
 * element.d registers its layout properties from a `shared static this()`,
 * this module must not have one: two module constructors in one import cycle
 * abort the program before main() with a cyclic-dependency error that names
 * neither the import nor the property behind it.
 *
 * Routed events declared here are built lazily through RoutedEventRegistry
 * for exactly that reason.  Register events belonging to a concrete element
 * from that element's own module, the way cherry.ui.input does.
 */

import cherry.core.multicast : EventAccessor, event;
import cherry.core.rtti;
import cherry.ui.element;

/**
 * How a routed event travels the element tree when raised.
 */
enum RoutingStrategy
{
    /// Only the handlers of the element that raised the event are invoked.
    direct,
    /// Handlers are invoked from the raising element up to the tree root.
    bubble,
    /// Handlers are invoked from the tree root down to the raising element.
    tunnel
}

/**
 * Signature of a routed event handler.
 *
 * `sender` is the element whose handler list is currently being invoked
 * (the DOM's currentTarget); the element that raised the event is available
 * as args.source.
 */
alias RoutedEventHandler = void delegate(Element sender, RoutedEventArgs args);

/**
 * Signature of a class handler: what a whole type does with an event, as
 * opposed to what one instance was asked to do about it.
 *
 * A function pointer and not a delegate, deliberately.  The table these are
 * kept in is global and is never emptied, so a handler able to capture an
 * instance would pin whatever it captured for the life of the process -- a leak
 * with nothing to catch it, since the registration usually happens in a module
 * constructor and is never looked at again.  With no context to capture there
 * is nothing to leak: the element to act on arrives as `sender`, which is how
 * WPF's static class handlers take it too.
 */
alias ClassHandler = void function(Element sender, RoutedEventArgs args);

/**
 * Identifies a registered routed event -- the sibling of Property for
 * events: an immutable identity object created once via register and then
 * shared by every element that adds handlers or raises the event.
 */
final immutable class RoutedEvent
{
   /**
    * Registers a new routed event.
    *
    * Params:
    *     name = Name of the event, unique within the owner type
    *     strategy = How the event travels the tree when raised
    *     ownerType = Type that is registering the event
    *
    * Returns:
    *     A new registered immutable RoutedEvent identity object
    */
    static immutable(RoutedEvent) register(string name,
                                           RoutingStrategy strategy,
                                           immutable(RttiClassType) ownerType)
    in {
        assert(name !is null && name != "");
        assert(ownerType !is null);
    }
    do {
        return new immutable(RoutedEvent)(name, strategy, ownerType);
    }

    @property string name() pure const nothrow
    {
        return _name;
    }

    @property RoutingStrategy routingStrategy() pure const nothrow
    {
        return _strategy;
    }

    @property immutable(RttiClassType) ownerType() pure const nothrow
    {
        return _ownerType;
    }

    @property uint id() pure const nothrow
    {
        return _id;
    }

   /**
    * Registers a handler that every instance of a type runs for this event,
    * ahead of any handler added to one of them.
    *
    * The sibling of Property.overrideMetadata, and shaped the same way: the
    * identity object is asked to record something about a type.
    * ---
    * mouseDownEvent.registerClassHandler(getRtti!Button(), &Button.pressed);
    * ---
    * This is where the behaviour a control is made of belongs.  A control that
    * subscribes to its own events instead stands in the same queue as the code
    * using it -- so its behaviour runs whenever it happened to subscribe, and
    * an event it marks handled silences handlers that had every right to run.
    *
    * Order on one element: class handlers first, most derived class first, then
    * the instance's own.  A derived class getting in front of its base is the
    * point of that order -- it can settle the event and the base never sees it.
    *
    * `forType` need not derive from this event's owner: a window class-handling
    * the Click of the buttons inside it is a use, not an abuse.  It must derive
    * from Element, because that is what a handler is given.
    *
    * Handlers accumulate, in the order they were registered -- unlike
    * overrideMetadata, which refuses a second override, because metadata is one
    * value and handlers are a list.  There is no way to take one back, in this
    * framework or in WPF: a class handler is part of what the type is.
    */
    void registerClassHandler(immutable(RttiClassType) forType,
                              ClassHandler handler,
                              bool handledEventsToo = false) const
    in {
        assert(forType !is null);
        assert(handler !is null);
    }
    do {
        if (!getRtti!Element().isAssignableFrom(forType))
            throw new Exception(forType.name ~ ": only types derived from Element can class-handle "
                ~ _ownerType.name ~ '.' ~ _name ~ ", because a class handler is given an element.");

        RoutedEventRegistry.get().addClassHandler(_id, forType, handler, handledEventsToo);
    }

private:
    this(string name, RoutingStrategy strategy, immutable(RttiClassType) ownerType)
    {
        _name = name;
        _strategy = strategy;
        _ownerType = ownerType;
        _id = RoutedEventRegistry.get().add(this, ownerType.name ~ '.' ~ name);
    }

    string          _name;
    RoutingStrategy _strategy;
    RttiClassType   _ownerType;
    uint            _id;
}

/**
 * Travels the route when a routed event is raised: carries the event
 * identity, the raising element and the handled flag (the analogue of a
 * DOM Event instance).
 */
class RoutedEventArgs
{
    this(immutable(RoutedEvent) routedEvent)
    in {
        assert(routedEvent !is null);
    }
    do {
        _routedEvent = routedEvent;
    }

   /**
    * The routed event this instance is travelling for.
    */
    @property immutable(RoutedEvent) routedEvent() pure const nothrow
    {
        return _routedEvent;
    }

   /**
    * The element that raised the event.
    */
    @property Element source() pure nothrow
    {
        return _source;
    }

   /**
    * The element where the event originally started.  Equals source until
    * source adjustment (composite controls re-targeting the event) is
    * introduced.
    */
    @property Element originalSource() pure nothrow
    {
        return _originalSource;
    }

   /**
    * When set by a handler, the remaining handlers on the route are skipped
    * unless they subscribed with handledEventsToo.
    */
    @property bool handled() pure const nothrow
    {
        return _handled;
    }

    @property void handled(bool value) pure nothrow
    {
        _handled = value;
    }

package(cherry.ui):
   /*
    * Stamps the raising element onto the args right before routing starts.
    * Package-protected: only the routing code in Element may call it.
    */
    void initializeRoute(Element raiser) pure nothrow
    {
        _source = raiser;
        _originalSource = raiser;
    }

private:
    immutable(RoutedEvent) _routedEvent;
    Element _source;
    Element _originalSource;
    bool    _handled;
}

/**
 * Builds an EventAccessor for a routed event on an element -- the routed
 * counterpart of the plain eventAccessor(&field).  The accessor's `~=` and
 * `-=` forward to the element's addEventHandler/removeEventHandler, giving
 * the Delphi/C#-style subscription syntax:
 * ---
 * @event @property auto onClick() { return routedAccessor(this, clickEvent); }
 *
 * button.onClick ~= &onButtonClick;
 * button.onClick -= &onButtonClick;
 * ---
 * Subscribing with handledEventsToo still requires an explicit
 * addEventHandler call.
 */
EventAccessor!RoutedEventHandler routedAccessor(Element element, immutable(RoutedEvent) event)
in {
    assert(element !is null);
    assert(event !is null);
}
do {
    return EventAccessor!RoutedEventHandler(
        (RoutedEventHandler h) { element.addEventHandler(event, h); },
        (RoutedEventHandler h) { element.removeEventHandler(event, h); });
}

/**
 * Runs the class handlers that apply to an element, in the tier's own order.
 *
 * Lives here rather than in Element so that the entries stay private to the
 * registry: what an element needs is not the list but the effect of it.
 */
package(cherry.ui) void invokeClassHandlers(Element element, RoutedEventArgs args)
{
    foreach (entry; RoutedEventRegistry.get().classHandlers(args.routedEvent.id, typeid(element)))
    {
        if (!args.handled || entry.handledEventsToo)
            entry.handler(element, args);
    }
}

/**
 * Central registry of routed events: assigns ids, enforces per-owner name
 * uniqueness, and holds the class handlers registered for each type.
 */
final class RoutedEventRegistry
{
    static RoutedEventRegistry get()
    {
        if ( !_instantiated )
        {
            synchronized ( RoutedEventRegistry.classinfo )
            {
                if ( !_instance )
                {
                    _instance = new RoutedEventRegistry;
                }

                _instantiated = true;
            }
        }

        return _instance;
    }

private:
    uint add(immutable(RoutedEvent) event, string fullName)
    {
        synchronized ( RoutedEventRegistry.classinfo )
        {
            if (fullName in _eventByName)
                throw new Exception(fullName ~ ": a routed event with the same name is already registered for this type.");

            uint id = cast(uint) _events.length;
            _events ~= EventContainer(event);
            _eventByName[fullName] = id;
            return id;
        }
    }

    void addClassHandler(uint eventId, immutable(RttiClassType) forType,
                         ClassHandler handler, bool handledEventsToo)
    {
        synchronized ( RoutedEventRegistry.classinfo )
        {
            _events[eventId].byType[forType.name] ~= ClassEntry(handler, handledEventsToo);

            // Every list resolved for this event may now be short of a handler,
            // since each is merged from a whole class chain and this type may
            // sit anywhere on it.  Registrations live in module constructors,
            // so in practice this throws away a cache nobody has filled yet --
            // and it keeps a late registration honest, which is worth more than
            // the cache.
            _events[eventId].resolved = null;
        }
    }

   /*
    * The class handlers that apply to an object of this exact type, most
    * derived first.
    *
    * The walk is over TypeInfo_Class rather than the Rtti graph, because it has
    * to start from what the object actually is.  Each level is looked up by
    * name, exactly as CherryObject.rtti resolves per-type property metadata:
    * registration hands in an RttiClassType and rttiForName hands the same
    * object back, so the two sides always agree on the key.  A class that never
    * asked for RTTI -- most classes, since RTTI comes of registering something
    * -- is simply skipped, and its base's handlers still apply to it.
    */
    const(ClassEntry)[] classHandlers(uint eventId, TypeInfo_Class dynamicType)
    {
        synchronized ( RoutedEventRegistry.classinfo )
        {
            if (auto cached = dynamicType.name in _events[eventId].resolved)
                return *cached;

            ClassEntry[] merged;

            for (TypeInfo_Class type = dynamicType; type !is null; type = type.base)
            {
                auto rtti = rttiForName(type.name);
                if (rtti is null)
                    continue;

                if (auto own = rtti.name in _events[eventId].byType)
                    merged ~= *own;
            }

            _events[eventId].resolved[dynamicType.name] = merged;
            return merged;
        }
    }

    this()
    {
    }

    struct ClassEntry
    {
        ClassHandler handler;
        bool         handledEventsToo;
    }

    struct EventContainer
    {
        immutable(RoutedEvent) event;
        // What each type registered, by RttiClassType.name.
        ClassEntry[][string]   byType;
        // The merged chain for a dynamic type, by TypeInfo_Class.name.  A cache
        // of the walk above and nothing more; addClassHandler drops it.
        ClassEntry[][string]   resolved;
    }

    __gshared RoutedEventRegistry _instance;
    static bool                   _instantiated;   // thread-local fast-path guard
    EventContainer[]              _events;
    uint[string]                  _eventByName;
}

unittest
{
    import std.exception : assertThrown;

    static class Panel : Element
    {
    }

    static class Other : Element
    {
    }

    // Registration and identity.
    auto clickEvent = RoutedEvent.register("Click", RoutingStrategy.bubble, getRtti!Panel());
    assert(clickEvent.name == "Click");
    assert(clickEvent.routingStrategy == RoutingStrategy.bubble);
    assert(clickEvent.ownerType is getRtti!Panel());

    // A duplicate name for the same owner is rejected; the same name for a
    // different owner is fine.
    assertThrown(RoutedEvent.register("Click", RoutingStrategy.bubble, getRtti!Panel()));
    auto otherClick = RoutedEvent.register("Click", RoutingStrategy.bubble, getRtti!Other());
    assert(otherClick.id != clickEvent.id);

    auto previewEvent = RoutedEvent.register("PreviewClick", RoutingStrategy.tunnel, getRtti!Panel());
    auto pokeEvent    = RoutedEvent.register("Poke", RoutingStrategy.direct, getRtti!Panel());

    // Tree: root -> mid -> leaf.
    auto root = new Element;
    auto mid  = new Element;
    auto leaf = new Element;
    root.addChild(mid);
    mid.addChild(leaf);

    string[]  log;
    Element[] senders;

    RoutedEventHandler make(string tag)
    {
        return (Element sender, RoutedEventArgs args) {
            log ~= tag;
            senders ~= sender;
        };
    }

    root.addEventHandler(clickEvent, make("root"));
    mid.addEventHandler(clickEvent, make("mid"));
    leaf.addEventHandler(clickEvent, make("leaf"));

    // Bubble: target first, then up to the root.
    auto args = new RoutedEventArgs(clickEvent);
    leaf.raiseEvent(args);
    assert(log == ["leaf", "mid", "root"]);
    assert(senders == [leaf, mid, root]);
    assert(args.source is leaf);
    assert(args.originalSource is leaf);
    assert(!args.handled);

    // Raising from the middle: the route starts there.
    log = null;
    senders = null;
    mid.raiseEvent(new RoutedEventArgs(clickEvent));
    assert(log == ["mid", "root"]);

    // Tunnel: root first, down to the target.
    log = null;
    senders = null;
    root.addEventHandler(previewEvent, make("root"));
    mid.addEventHandler(previewEvent, make("mid"));
    leaf.addEventHandler(previewEvent, make("leaf"));
    leaf.raiseEvent(new RoutedEventArgs(previewEvent));
    assert(log == ["root", "mid", "leaf"]);
    assert(senders == [root, mid, leaf]);

    // Direct: only the raising element.
    log = null;
    senders = null;
    root.addEventHandler(pokeEvent, make("root"));
    leaf.addEventHandler(pokeEvent, make("leaf"));
    leaf.raiseEvent(new RoutedEventArgs(pokeEvent));
    assert(log == ["leaf"]);

    // A detached element routes to itself only.
    log = null;
    senders = null;
    auto lone = new Element;
    lone.addEventHandler(clickEvent, make("lone"));
    lone.raiseEvent(new RoutedEventArgs(clickEvent));
    assert(log == ["lone"]);

    // handled skips the remaining handlers, except those subscribed with
    // handledEventsToo.
    auto stopEvent = RoutedEvent.register("Stop", RoutingStrategy.bubble, getRtti!Panel());
    log = null;
    leaf.addEventHandler(stopEvent, (Element sender, RoutedEventArgs a) {
        log ~= "leaf";
        a.handled = true;
    });
    mid.addEventHandler(stopEvent, (Element sender, RoutedEventArgs a) {
        log ~= "mid";
    });
    root.addEventHandler(stopEvent, (Element sender, RoutedEventArgs a) {
        log ~= "root+handled";
    }, true);
    auto stopArgs = new RoutedEventArgs(stopEvent);
    leaf.raiseEvent(stopArgs);
    assert(stopArgs.handled);
    assert(log == ["leaf", "root+handled"]);

    // removeHandler removes one registration at a time and ignores
    // handlers that are not registered.
    auto rmEvent = RoutedEvent.register("Rm", RoutingStrategy.direct, getRtti!Panel());
    RoutedEventHandler h = (Element sender, RoutedEventArgs a) { log ~= "h"; };
    leaf.addEventHandler(rmEvent, h);
    leaf.addEventHandler(rmEvent, h);
    log = null;
    leaf.raiseEvent(new RoutedEventArgs(rmEvent));
    assert(log == ["h", "h"]);
    leaf.removeEventHandler(rmEvent, h);
    log = null;
    leaf.raiseEvent(new RoutedEventArgs(rmEvent));
    assert(log == ["h"]);
    leaf.removeEventHandler(rmEvent, h);
    leaf.removeEventHandler(rmEvent, h); // not registered: no-op
    log = null;
    leaf.raiseEvent(new RoutedEventArgs(rmEvent));
    assert(log.length == 0);
}

unittest
{
    // The Delphi-style subscription syntax through routedAccessor.
    //
    // A real control registers its events in a shared static this of its own
    // module and stores them in static immutable fields; here the event is
    // passed through the constructor instead, because event.d and element.d
    // import each other and a module constructor in this module would create
    // a cycle.
    static class Button : Element
    {
        this(immutable(RoutedEvent) clickEvent)
        {
            _clickEvent = clickEvent;
        }

        @event @property auto onClick()
        {
            return routedAccessor(this, _clickEvent);
        }

        private immutable(RoutedEvent) _clickEvent;
    }

    auto clickEvent = RoutedEvent.register("AccessorClick", RoutingStrategy.bubble, getRtti!Button());

    auto panel  = new Element;
    auto button = new Button(clickEvent);
    panel.addChild(button);

    string[] log;

    void onButtonClick(Element sender, RoutedEventArgs args)
    {
        log ~= "clicked";
    }

    // Subscription through ~= on the accessor property.
    button.onClick ~= &onButtonClick;
    button.raiseEvent(new RoutedEventArgs(clickEvent));
    assert(log == ["clicked"]);

    // Handlers added through an accessor participate in routing as usual.
    auto panelClick = routedAccessor(panel, clickEvent);
    panelClick ~= (Element sender, RoutedEventArgs args) { log ~= "panel"; };
    log = null;
    button.raiseEvent(new RoutedEventArgs(clickEvent));
    assert(log == ["clicked", "panel"]);

    // -= removes one registration.
    button.onClick -= &onButtonClick;
    log = null;
    button.raiseEvent(new RoutedEventArgs(clickEvent));
    assert(log == ["panel"]);
}

version (unittest)
{
   /*
    * Where the class-handler tests write, and why they need somewhere to write.
    *
    * A class handler cannot close over a test's local variable -- that is the
    * whole point of it being a function pointer -- so what it says has to go
    * somewhere it can reach without a context.  Thread-local module storage is
    * that somewhere, and every test below empties it before raising anything.
    */
    private string[] classLog;

    private ClassHandler logging(string tag)()
    {
        return function(Element sender, RoutedEventArgs args) { classLog ~= tag; };
    }

    private ClassHandler claiming(string tag)()
    {
        return function(Element sender, RoutedEventArgs args) {
            classLog ~= tag;
            args.handled = true;
        };
    }
}

unittest
{
    // The class tier runs before the instance queue on the same element.
    static class Widget : Element { }

    auto tierEvent = RoutedEvent.register("Tier", RoutingStrategy.direct, getRtti!Widget());
    tierEvent.registerClassHandler(getRtti!Widget(), logging!"class");

    auto widget = new Widget;
    widget.addEventHandler(tierEvent, (Element sender, RoutedEventArgs args) { classLog ~= "instance"; });

    classLog = null;
    widget.raiseEvent(new RoutedEventArgs(tierEvent));

    assert(classLog == ["class", "instance"]);
}

unittest
{
    // Most derived first, then the base -- and not the order they were
    // registered in, which is why the base goes in first here.
    static class Base : Element { }
    static class Derived : Base { }

    auto chainEvent = RoutedEvent.register("Chain", RoutingStrategy.direct, getRtti!Base());
    chainEvent.registerClassHandler(getRtti!Base(), logging!"base");
    chainEvent.registerClassHandler(getRtti!Derived(), logging!"derived");

    classLog = null;
    (new Derived).raiseEvent(new RoutedEventArgs(chainEvent));
    assert(classLog == ["derived", "base"]);

    // The base hears only its own: a handler registered for a derived class is
    // not something every element of the base type has to run.
    classLog = null;
    (new Base).raiseEvent(new RoutedEventArgs(chainEvent));
    assert(classLog == ["base"]);
}

unittest
{
    // A derived class settling the event stops the base class handler and the
    // instance queue alike -- everything except what asked for handled events.
    static class Base : Element { }
    static class Derived : Base { }

    auto claimEvent = RoutedEvent.register("Claim", RoutingStrategy.direct, getRtti!Base());
    claimEvent.registerClassHandler(getRtti!Base(), logging!"base");
    claimEvent.registerClassHandler(getRtti!Derived(), claiming!"derived");
    claimEvent.registerClassHandler(getRtti!Derived(), logging!"derived-too", true);

    auto derived = new Derived;
    derived.addEventHandler(claimEvent, (Element sender, RoutedEventArgs args) { classLog ~= "instance"; });
    derived.addEventHandler(claimEvent, (Element sender, RoutedEventArgs args) { classLog ~= "instance-too"; }, true);

    classLog = null;
    derived.raiseEvent(new RoutedEventArgs(claimEvent));

    assert(classLog == ["derived", "derived-too", "instance-too"]);
}

unittest
{
    // A type may class-handle an event it has nothing to do with: this is the
    // window that wants to hear the Click of every button inside it.
    static class Owner : Element { }
    static class Panel : Element { }

    auto foreignEvent = RoutedEvent.register("Foreign", RoutingStrategy.bubble, getRtti!Owner());
    foreignEvent.registerClassHandler(getRtti!Panel(), logging!"panel");

    auto panel = new Panel;
    auto owner = new Owner;
    panel.addChild(owner);

    classLog = null;
    owner.raiseEvent(new RoutedEventArgs(foreignEvent));

    assert(classLog == ["panel"], "heard on the way up, on a type the event knows nothing about");
}

unittest
{
    // A class nobody ever asked for RTTI about -- which is most classes, since
    // RTTI comes of registering something -- still runs its base's handlers.
    static class Known : Element { }
    static class Unknown : Known { }

    auto inheritedEvent = RoutedEvent.register("Inherited", RoutingStrategy.direct, getRtti!Known());
    inheritedEvent.registerClassHandler(getRtti!Known(), logging!"known");

    classLog = null;
    (new Unknown).raiseEvent(new RoutedEventArgs(inheritedEvent));

    assert(classLog == ["known"]);
}

unittest
{
    // The tier travels the whole route, in the direction the event travels --
    // and the handler learns which element it is on from the sender, which is
    // the only way it can, having no instance of its own.
    static class Node : Element
    {
        string name;
        this(string name) { this.name = name; }
    }

    auto upEvent = RoutedEvent.register("TierUp", RoutingStrategy.bubble, getRtti!Node());
    auto downEvent = RoutedEvent.register("TierDown", RoutingStrategy.tunnel, getRtti!Node());
    auto hereEvent = RoutedEvent.register("TierHere", RoutingStrategy.direct, getRtti!Node());

    auto naming = function(Element sender, RoutedEventArgs args) {
        classLog ~= (cast(Node) sender).name;
    };

    upEvent.registerClassHandler(getRtti!Node(), naming);
    downEvent.registerClassHandler(getRtti!Node(), naming);
    hereEvent.registerClassHandler(getRtti!Node(), naming);

    auto root = new Node("root");
    auto mid = new Node("mid");
    auto leaf = new Node("leaf");
    root.addChild(mid);
    mid.addChild(leaf);

    classLog = null;
    leaf.raiseEvent(new RoutedEventArgs(upEvent));
    assert(classLog == ["leaf", "mid", "root"]);

    classLog = null;
    leaf.raiseEvent(new RoutedEventArgs(downEvent));
    assert(classLog == ["root", "mid", "leaf"]);

    classLog = null;
    leaf.raiseEvent(new RoutedEventArgs(hereEvent));
    assert(classLog == ["leaf"]);
}

unittest
{
    // Registering after the event has already been raised on the type works:
    // the merged list is a cache of a walk, and the cache is dropped when
    // anything is added to it.
    static class Late : Element { }

    auto lateEvent = RoutedEvent.register("Late", RoutingStrategy.direct, getRtti!Late());
    auto late = new Late;

    classLog = null;
    late.raiseEvent(new RoutedEventArgs(lateEvent));
    assert(classLog.length == 0, "nothing registered yet -- and the empty answer is now cached");

    lateEvent.registerClassHandler(getRtti!Late(), logging!"late");

    classLog = null;
    late.raiseEvent(new RoutedEventArgs(lateEvent));
    assert(classLog == ["late"], "which did not stop the handler arriving late");
}

unittest
{
    import std.exception : assertThrown;

    // A class handler is given an element, so a type that is not one cannot
    // have any.
    static class Widget : Element { }
    static class Stranger { }

    auto strangerEvent = RoutedEvent.register("Stranger", RoutingStrategy.direct, getRtti!Widget());

    assertThrown(strangerEvent.registerClassHandler(getRtti!Stranger(), logging!"never"));
}
