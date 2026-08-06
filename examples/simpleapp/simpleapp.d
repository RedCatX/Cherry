module simpleapp;

import cherry.ui.application;

import mainwin : MainWindow;

mixin ApplicationEntryPoint!SimpleApp;

class SimpleApp : UIApplication
{
    this(string[] args)
    {
        super(args);
	}

    static int main(string[] args)
    {
        auto app = new SimpleApp(args);
        
        return app.run(new MainWindow);
    }
}

