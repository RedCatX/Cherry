module hello;

import std.stdio : writefln;

import cherry.core;
import cherry.ui;
import cherry.platform;

class HelloWindow : Window
{
   /**
    * The brushes are built once and kept.  A brush is an object with
    * properties, not a value, so making one per frame would be making one per
    * frame -- and the backend caches its device resources against the object,
    * so a fresh brush every time would defeat that too.
    */
    this()
    {
        _stem = new SolidColorBrush(Color.rgb(0.45, 0.30, 0.12));
        _leaf = new SolidColorBrush(Color.rgb(0.22, 0.62, 0.28));
        _dark = new SolidColorBrush(Color.rgb(0.82, 0.06, 0.16));
        _bright = new SolidColorBrush(Color.rgb(0.90, 0.10, 0.20));
        _shine = new SolidColorBrush(Color.rgb(1.0, 0.55, 0.60));
    }

    protected override void onRender(DrawingContext context)
    {
        // Stems.
        context.drawLine(Point(400, 120), Point(330, 270), _stem, 6);
        context.drawLine(Point(400, 120), Point(470, 260), _stem, 6);

        // A leaf at the join.
        context.fillEllipse(Rect(392, 96, 110, 44), _leaf);

        // The cherries.
        context.fillEllipse(Rect(265, 265, 130, 130), _dark);
        context.fillEllipse(Rect(405, 255, 140, 140), _bright);

        // Highlights.
        context.fillEllipse(Rect(295, 290, 28, 22), _shine);
        context.fillEllipse(Rect(440, 285, 30, 24), _shine);
    }

private:
    SolidColorBrush _stem, _leaf, _dark, _bright, _shine;
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
    this(string name, Color color, float thickness)
    {
        _name = name;
        _plain = new SolidColorBrush(color);
        _lit = new SolidColorBrush(lighten(color));
        height = thickness;

        // The pointer arriving and leaving is all the state a hover needs.
        // The repaint is asked for by hand: IsMouseOver deliberately does not
        // carry affectsRender, because most elements on the chain look exactly
        // the same hovered as not, and a control that does change says so.
        this.onMouseEnter ~= (Element sender, RoutedEventArgs args) { invalidateVisual(); };
        this.onMouseLeave ~= (Element sender, RoutedEventArgs args) { invalidateVisual(); };

        this.onMouseDown ~= (Element sender, RoutedEventArgs args) {
            auto mouse = cast(MouseEventArgs) args;
            auto local = mouse.getPosition(this);
            writefln("%s clicked at (%.0f, %.0f) of its own space", _name, local.x, local.y);

            // Claimed, so the window's own handler leaves it alone -- the band
            // dealt with this click and nobody above needs to guess whether it
            // was meant for them.
            args.handled = true;
        };
    }

    protected override void onRender(DrawingContext context)
    {
        context.fillRectangle(Rect(0, 0, actualWidth, actualHeight),
                              isMouseOver ? _lit : _plain);
    }

private:
    static Color lighten(Color c)
    {
        return Color.rgb(c.r + (1 - c.r) * 0.45,
                         c.g + (1 - c.g) * 0.45,
                         c.b + (1 - c.b) * 0.45);
    }

    string          _name;
    SolidColorBrush _plain;
    SolidColorBrush _lit;
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

    // Each band lights up under the pointer and names itself when clicked.
    // Nothing here says where any of them is: the hit test walks the same
    // placements the render walk does, so a band that the panel moves is a band
    // the mouse follows.
    stripes.addChild(new Swatch("dark red", Color.rgb(0.82, 0.06, 0.16), 40));
    stripes.addChild(new Swatch("bright red", Color.rgb(0.90, 0.10, 0.20), 26));

    auto inset = new Swatch("green", Color.rgb(0.22, 0.62, 0.28), 26);
    inset.margin = Thickness(24, 0, 8, 0);
    stripes.addChild(inset);

    stripes.addChild(new Swatch("brown", Color.rgb(0.45, 0.30, 0.12), 12));

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

    // Everything a band did not claim arrives here on the way up, with args
    // naming whatever was actually under the pointer.
    window.onMouseDown ~= (Element sender, RoutedEventArgs args) {
        auto mouse = cast(MouseEventArgs) args;
        writefln("mouse %s down at (%.0f, %.0f) over %s",
                 mouse.button, mouse.x, mouse.y, typeid(args.source).name);

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
