module cherry.ui.controls;

/**
 * The controls: the elements a user sees and works with.
 *
 * cherry.ui below this holds the machinery -- the tree, the property and
 * event plumbing, the layout pass, the window.  This package holds what is
 * built out of it, and the dependency runs one way: a control imports the
 * machinery, and the machinery never imports a control.
 *
 * That is not tidiness.  It is what lets a control register its properties
 * from a module constructor of its own without joining an import cycle, which
 * would abort every binary built against the framework before main().  The
 * banner in stackpanel.d spells it out.
 */

public import cherry.ui.controls.button;
public import cherry.ui.controls.control;
public import cherry.ui.controls.grid;
public import cherry.ui.controls.stackpanel;
public import cherry.ui.controls.textblock;
