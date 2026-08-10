module hello;

import std.stdio : writefln;

import cherry.core;
import cherry.ui;
import cherry.platform;

/**
 * The cherries, drawn to fit whatever room they are given.
 *
 * **An element rather than something the window paints on itself**, and that is
 * the difference worth seeing: a drawing at fixed coordinates on the window
 * stays exactly where it is however the window is resized, because nothing about
 * it is a layout.  This one is in a cell, so the cell decides.
 *
 * The artwork keeps the coordinates it was drawn in, and a transform puts it
 * where it belongs -- which is what the transform stack is for.  Nothing here
 * recalculates a single ellipse; the whole picture is placed with one matrix.
 */
class Cherries : Element
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

protected:
   /**
    * How big the picture would like to be, which is how big it was drawn.
    *
    * It gets a star cell here so nobody asks, but an auto cell would -- and
    * then the column would be as wide as the cherries, which is the answer an
    * auto column is for.
    */
    override Size measureOverride(Size availableSize)
    {
        return Size(artWidth, artHeight);
    }

    override void onRender(DrawingContext context)
    {
        // As large as it can be without distorting, centred in what is left.
        immutable byWidth = actualWidth / artWidth;
        immutable byHeight = actualHeight / artHeight;
        immutable scale = byWidth < byHeight ? byWidth : byHeight;

        if (!(scale > 0))
            return;

        // Read left to right: take the artwork to the origin, size it, put it
        // in the middle.  A * B means "A and then B" -- see Matrix.
        context.pushTransform(Matrix.translation(-artX, -artY)
                            * Matrix.scaling(scale, scale)
                            * Matrix.translation((actualWidth - artWidth * scale) / 2,
                                                 (actualHeight - artHeight * scale) / 2));
        scope (exit) context.popTransform();

        // Stems.
        context.drawLine(Point(400, 120), Point(330, 270), Stroke(_stem, 6));
        context.drawLine(Point(400, 120), Point(470, 260), Stroke(_stem, 6));

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
    // The box the drawing above occupies, in its own coordinates.
    enum artX = 265.0f;
    enum artY = 96.0f;
    enum artWidth = 280.0f;
    enum artHeight = 300.0f;

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

        // A ramp down the band rather than a flat colour.  Nothing here says
        // how tall the band is: a gradient's ends are fractions of whatever it
        // fills, so the same brush would work on a band of any height -- which
        // is the whole reason they are fractions.
        _plain = new LinearGradientBrush(lighten(color, 0.18), color);
        _lit = new LinearGradientBrush(lighten(color, 0.6), lighten(color, 0.3));

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
    static Color lighten(Color c, float amount)
    {
        return Color.rgb(c.r + (1 - c.r) * amount,
                         c.g + (1 - c.g) * amount,
                         c.b + (1 - c.b) * amount);
    }

    string _name;
    LinearGradientBrush _plain;
    LinearGradientBrush _lit;
}

// The same words in the window and in the system's own dialog, so the two can
// be held up against each other.  See the button's click handler.
private enum sample = "The quick brown fox jumps over the lazy dog.";

/**
 * A button that changes colour as it is used.
 *
 * **It watches the state, not the events**, and the difference is worth
 * knowing.  Button handles MouseDown and MouseUp itself and marks them
 * handled -- a press on a button is not also a press on what it sits in -- and
 * a handled event skips every handler after it on the same element, this one
 * included.  So subscribing to the mouse here would work for entering and
 * leaving and quietly do nothing for pressing.  WPF's ButtonBase behaves the
 * same way, and the same answer applies: read IsPressed and IsMouseOver.
 *
 * This override is what a style trigger will be, once there are styles.
 */
class HelloButton : Button
{
    this(string caption)
    {
        text = caption;
        cornerRadius = 5;
        borderThickness = Thickness(1);
        borderBrush = new SolidColorBrush(Color.rgb(0.62, 0.16, 0.22));

        _normal = new LinearGradientBrush(Color.rgb(0.98, 0.93, 0.94), Color.rgb(0.93, 0.84, 0.86));
        _hot = new LinearGradientBrush(Color.white, Color.rgb(0.97, 0.90, 0.92));
        _pressed = new LinearGradientBrush(Color.rgb(0.88, 0.76, 0.79), Color.rgb(0.94, 0.86, 0.88));

        background = _normal;
    }

protected:
    override void onPropertyChanged(immutable(Property) property,
                                    ref immutable(PropertyMetadata) metadata,
                                    const(Value) oldValue,
                                    const(Value) newValue)
    {
        super.onPropertyChanged(property, metadata, oldValue, newValue);

        // The brushes are built after the base constructor has run, and the
        // base constructor sets properties -- so this can be reached before
        // there is anything to paint with.
        if (_normal is null)
            return;

        if (property is Button.isPressedProperty || property is Element.isMouseOverProperty)
            background = isPressed ? _pressed : (isMouseOver ? _hot : _normal);
    }

private:
    LinearGradientBrush _normal, _hot, _pressed;
}

void main()
{
    auto dispatcher = new Dispatcher(createPlatformEventLoop());

    auto window = new Window;
    window.title = "Hello from Cherry!";

    // The window is one cell, so anything with more than one thing in it needs
    // something that divides.  Two columns and two rows: the stripes take the
    // width they need, the drawing takes everything left over, and the line
    // along the bottom takes the height it needs across both.
    //
    // What a stack could not do is the middle of that.  A stack hands each
    // child the length it asked for; nothing in it ever gets "the rest".
    auto layout = new Grid;
    layout.addColumn(GridLength.autoSize);
    layout.addColumn(GridLength.star(1));
    layout.addRow(GridLength.star(1));
    layout.addRow(GridLength.autoSize);
    layout.rowSpacing = 12;

    window.addChild(layout);

    // A column down the left, laid out by the framework rather than by hand:
    // the panel is 160 wide, its children have a height each and no opinion
    // about width, and the gaps between them come half from the panel's spacing
    // and half from one child's own margin.
    auto stripes = new StackPanel;
    stripes.width = 160;
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

    // Nothing says how big it is: the label asks the text service how wide the
    // word is, Control adds its padding, and the stack panel takes that as the
    // height it needs.  Across the column it stretches, because that is what
    // an alignment nobody set means.
    auto button = new HelloButton("Compare");
    button.margin = Thickness(0, 10, 0, 0);

    // Enter presses it from anywhere in the window -- unless whatever has the
    // keyboard wants Enter for itself, which is the whole of what "default"
    // means.  Tab walks between the two buttons and each draws a ring while it
    // has the keyboard; Space presses the focused one on the way up, so it can
    // still be taken back by Tabbing away before letting go.
    button.isDefault = true;
    stripes.addChild(button);

    button.onClick ~= (Element sender, RoutedEventArgs args) {
        // The same sentence, drawn by the system instead of by us.  A
        // MessageBox is a classic GDI dialog, which is the picture
        // TextRendering.display is meant to be indistinguishable from: hold the
        // box next to the line along the bottom of the window and look at the
        // letter shapes and the spacing.
        showMessage("Cherry", sample, MessageKind.information);
    };

    auto close = new HelloButton("Close");
    close.margin = Thickness(0, 6, 0, 0);
    close.isCancel = true;
    stripes.addChild(close);

    close.onClick ~= (Element sender, RoutedEventArgs args) {
        window.close();
    };

    // Top left, in the column that is as wide as its content.  Nothing here
    // says 160 twice: the column asked the panel how wide it wanted to be.
    Grid.setColumn(stripes, 0);
    Grid.setRow(stripes, 0);
    layout.addChild(stripes);

    // And the picture in the column that takes everything left over, which is
    // the whole point of the grid: drag the window wider and the cherries grow
    // while the stripes stay exactly as wide as they need to be.
    auto cherries = new Cherries;
    Grid.setColumn(cherries, 1);
    Grid.setRow(cherries, 0);
    layout.addChild(cherries);

    // Along the bottom and across both columns, in the row that is as tall as
    // the text in it -- so the line sits where it sits because of what it is,
    // not because somebody measured the window and left a margin.
    auto footer = new TextBlock;
    footer.text = sample;
    footer.horizontalAlignment = HorizontalAlignment.center;
    footer.margin = Thickness(0, 0, 0, 12);

    Grid.setRow(footer, 1);
    Grid.setColumnSpan(footer, 2);
    layout.addChild(footer);

    // Everything a band or the button did not claim arrives here on the way up,
    // with args naming whatever was actually under the pointer.
    window.onMouseDown ~= (Element sender, RoutedEventArgs args) {
        auto mouse = cast(MouseEventArgs) args;
        writefln("mouse %s down at (%.0f, %.0f) over %s",
                 mouse.button, mouse.x, mouse.y, typeid(args.source).name);
    };

    // shutdown() is shared -- callable from any thread; run() is not.
    window.onClosed ~= (Window w) { (cast(shared) dispatcher).shutdown(); };

    window.show();
    dispatcher.run();
}
