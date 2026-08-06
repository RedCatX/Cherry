module mainwin;

import cherry.ui.window;

class MainWindow : Window
{
    this()
	{
        initializeComponents();
	}

    void initializeComponents()
    {
        title = "Simple App";
    }
}
