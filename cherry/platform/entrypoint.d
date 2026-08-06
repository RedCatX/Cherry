module cherry.platform.entrypoint;

mixin template PlatformEntryPoint(alias appMain)
{
    version (Windows)
    {
        public import cherry.platform.win32.entrypoint : Win32EntryPoint;
        mixin Win32EntryPoint!appMain;
    }
    else
    {
        int main(string[] args) { return appMain(args); }
    }
}