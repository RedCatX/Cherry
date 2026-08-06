module cherry.platform.win32.entrypoint;

mixin template Win32EntryPoint(alias appMain)
{
    import core.sys.windows.windows : HINSTANCE, LPSTR;

    private alias extern(C) int function(string[]) _CherryFn;
    private extern (C) int _d_run_main(int, char**, _CherryFn);
    
    extern (Windows) int WinMain(HINSTANCE, HINSTANCE, LPSTR, int)
    {
        // argc and argv are deliberately empty: on Windows druntime ignores
        // them and reads the real command line through CommandLineToArgvW,
        // which is also the only way to get the arguments unmangled.  The
        // string array that reaches main is the genuine one.
        return _d_run_main(0, null, &_cherryShim);
    }

    private extern (C) int _cherryShim(string[] args)
    {
        return appMain(args);
    }
}