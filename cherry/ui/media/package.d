module cherry.ui.media;

/**
 * The things elements are drawn with rather than the things that are drawn:
 * brushes now, pens, geometries and transforms later.
 *
 * WPF keeps exactly this set in System.Windows.Media, and for the same reason
 * -- none of it is an element.  They are property-bearing objects that can be
 * bound and animated, shared between any number of elements, and never laid out
 * or hit.  That is what StyledElement, one layer below Visual, was placed low
 * enough to allow.
 *
 * The rule this package lives by, the same one the controls package has: import
 * downwards only.  Media may import the styled layer and the drawing model; the
 * machinery may not import media.
 */

public import cherry.ui.media.brush;
