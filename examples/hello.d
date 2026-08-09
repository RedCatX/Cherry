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

/**
 * A block of colour that fills whatever room it is given.
 *
 * It draws its own bounds and nothing else, because until there are brushes
 * there is no other way to see where a panel put something.  Note that it
 * paints at (0, 0): an element draws in a coordinate space of its own, and
 * the stack panel below moves these around without any of them knowing.
 */
class Swatch : Element
{
    this(Color color, float thickness)
    {
        _color = color;
        height = thickness;
    }

    protected override void onRender(DrawingContext context)
    {
        context.fillRectangle(Rect(0, 0, actualWidth, actualHeight), _color);
    }

private:
    Color _color;
}

// The same words in the window and in the system's own dialog, so the two can
// be held up against each other.  See the click handler at the bottom.
private enum sample = "The quick brown fox jumps over the lazy dog.";

void main()
{
    auto dispatcher = new Dispatcher(createPlatformEventLoop());

    auto window = new HelloWindow;
    window.setValue(Window.titleProperty, Value("Hello from Cherry!"));

    // A column down the left, laid out by the framework rather than by hand:
    // the panel is 160 wide and pinned to the left, its children have a height
    // each and no opinion about width, and the gaps between them come half
    // from the panel's spacing and half from one child's own margin.
    auto stripes = new StackPanel;
    stripes.width = 160;
    stripes.horizontalAlignment = HorizontalAlignment.left;
    stripes.verticalAlignment = VerticalAlignment.top;
    stripes.spacing = 6;

    // Nothing is said about the font, and that is the point: a TextBlock left
    // alone writes in the face and at the size Windows writes its own menus
    // in.  Its height is not stated either -- the panel asks the text how tall
    // it is, and the swatches below start under whatever it answers.
    auto caption = new TextBlock;
    caption.text = "Cherry";
    caption.fontSize = 20;
    caption.fontWeight = FontWeight.semiBold;
    caption.margin = Thickness(0, 0, 0, 4);

    stripes.addChild(caption);

    stripes.addChild(new Swatch(Color.rgb(0.82, 0.06, 0.16), 40));
    stripes.addChild(new Swatch(Color.rgb(0.90, 0.10, 0.20), 26));

    auto inset = new Swatch(Color.rgb(0.22, 0.62, 0.28), 26);
    inset.margin = Thickness(24, 0, 8, 0);
    stripes.addChild(inset);

    stripes.addChild(new Swatch(Color.rgb(0.45, 0.30, 0.12), 12));

    window.addChild(stripes);

    // A second child of the window, pinned along the bottom.  The window is a
    // single-cell container, so both children are offered the whole client
    // area and each takes the part of it its alignment asks for.
    auto footer = new TextBlock;
    footer.text = sample;
    footer.horizontalAlignment = HorizontalAlignment.center;
    footer.verticalAlignment = VerticalAlignment.bottom;
    footer.margin = Thickness(0, 0, 0, 12);

    window.addChild(footer);

    window.onMouseDown ~= (Element sender, RoutedEventArgs args) {
        auto mouse = cast(MouseEventArgs) args;
        writefln("mouse %s down at (%s, %s)", mouse.button, mouse.x, mouse.y);

        // The same sentence, drawn by the system instead of by us.  A
        // MessageBox is a classic GDI dialog, which is the picture
        // TextRendering.display is meant to be indistinguishable from: hold
        // the box next to the line along the bottom of the window and look at
        // the letter shapes and the spacing.
        showMessage("Cherry", sample, MessageKind.information);
    };

    // shutdown() is shared -- callable from any thread; run() is not.
    window.onClosed ~= (Window w) { (cast(shared) dispatcher).shutdown(); };

    window.show();
    dispatcher.run();
}
