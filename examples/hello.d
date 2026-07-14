module hello;

import std.stdio : writefln;

import cherry.core;
import cherry.ui;
import cherry.platform;

void main()
{
    auto dispatcher = new Dispatcher(createPlatformEventLoop());

    auto window = new Window;
    window.setValue(Window.titleProperty, Value("Hello from Cherry!"));

    window.onMouseDown ~= (Element sender, RoutedEventArgs args) {
        auto mouse = cast(MouseEventArgs) args;
        writefln("mouse %s down at (%s, %s)", mouse.button, mouse.x, mouse.y);
    };

    window.onClosed ~= (Window w) { dispatcher.shutdown(); };

    window.show();
    dispatcher.run();
}
