module cherry.ui.event;

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
 * Central registry of routed events: assigns ids and enforces per-owner
 * name uniqueness.
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
            _events ~= event;
            _eventByName[fullName] = id;
            return id;
        }
    }

    this()
    {
    }

    __gshared RoutedEventRegistry _instance;
    static bool                   _instantiated;   // thread-local fast-path guard
    immutable(RoutedEvent)[]      _events;
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

    root.addHandler(clickEvent, make("root"));
    mid.addHandler(clickEvent, make("mid"));
    leaf.addHandler(clickEvent, make("leaf"));

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
    root.addHandler(previewEvent, make("root"));
    mid.addHandler(previewEvent, make("mid"));
    leaf.addHandler(previewEvent, make("leaf"));
    leaf.raiseEvent(new RoutedEventArgs(previewEvent));
    assert(log == ["root", "mid", "leaf"]);
    assert(senders == [root, mid, leaf]);

    // Direct: only the raising element.
    log = null;
    senders = null;
    root.addHandler(pokeEvent, make("root"));
    leaf.addHandler(pokeEvent, make("leaf"));
    leaf.raiseEvent(new RoutedEventArgs(pokeEvent));
    assert(log == ["leaf"]);

    // A detached element routes to itself only.
    log = null;
    senders = null;
    auto lone = new Element;
    lone.addHandler(clickEvent, make("lone"));
    lone.raiseEvent(new RoutedEventArgs(clickEvent));
    assert(log == ["lone"]);

    // handled skips the remaining handlers, except those subscribed with
    // handledEventsToo.
    auto stopEvent = RoutedEvent.register("Stop", RoutingStrategy.bubble, getRtti!Panel());
    log = null;
    leaf.addHandler(stopEvent, (Element sender, RoutedEventArgs a) {
        log ~= "leaf";
        a.handled = true;
    });
    mid.addHandler(stopEvent, (Element sender, RoutedEventArgs a) {
        log ~= "mid";
    });
    root.addHandler(stopEvent, (Element sender, RoutedEventArgs a) {
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
    leaf.addHandler(rmEvent, h);
    leaf.addHandler(rmEvent, h);
    log = null;
    leaf.raiseEvent(new RoutedEventArgs(rmEvent));
    assert(log == ["h", "h"]);
    leaf.removeHandler(rmEvent, h);
    log = null;
    leaf.raiseEvent(new RoutedEventArgs(rmEvent));
    assert(log == ["h"]);
    leaf.removeHandler(rmEvent, h);
    leaf.removeHandler(rmEvent, h); // not registered: no-op
    log = null;
    leaf.raiseEvent(new RoutedEventArgs(rmEvent));
    assert(log.length == 0);
}
