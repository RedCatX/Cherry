module hello;

import std.stdio : writefln;

import cherry.core;
import cherry.ui;
import cherry.platform;

class HelloWindow : Window
{
    protected override void onRender(DrawingContext context)
    {
        // Stems.
        context.drawLine(Point(400, 120), Point(330, 270), Color.rgb(0.45, 0.30, 0.12), 6);
        context.drawLine(Point(400, 120), Point(470, 260), Color.rgb(0.45, 0.30, 0.12), 6);

        // A leaf at the join.
        context.fillEllipse(Rect(392, 96, 110, 44), Color.rgb(0.22, 0.62, 0.28));

        // The cherries.
        context.fillEllipse(Rect(265, 265, 130, 130), Color.rgb(0.82, 0.06, 0.16));
        context.fillEllipse(Rect(405, 255, 140, 140), Color.rgb(0.90, 0.10, 0.20));

        // Highlights.
        context.fillEllipse(Rect(295, 290, 28, 22), Color.rgb(1.0, 0.55, 0.60));
        context.fillEllipse(Rect(440, 285, 30, 24), Color.rgb(1.0, 0.55, 0.60));
    }
}

void main()
{
    auto dispatcher = new Dispatcher(createPlatformEventLoop());

    auto window = new HelloWindow;
    window.setValue(Window.titleProperty, Value("Hello from Cherry!"));

    window.onMouseDown ~= (Element sender, RoutedEventArgs args) {
        auto mouse = cast(MouseEventArgs) args;
        writefln("mouse %s down at (%s, %s)", mouse.button, mouse.x, mouse.y);
    };

    window.onClosed ~= (Window w) { dispatcher.shutdown(); };

    window.show();
    dispatcher.run();
}
