module mainwin;

import cherry.ui;
import cherry.core;

public MainWindow mainWindow;

class MainWindow : Window
{
    this()
	{
        initializeComponents();
	}

    void initializeComponents()
    {
        mixin(LoadComponents!("mainwin.juice"));
    }
}
