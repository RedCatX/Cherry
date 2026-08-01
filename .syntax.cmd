set PATH=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\bin\HostX86\x86;C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE;C:\Program Files (x86)\Windows Kits\10\bin;C:\D\dmd-2.112.0\windows\bin;%PATH%
set DMD_LIB=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\lib\x64;C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.26100.0\um\x64
set VCINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\VC\
set VCTOOLSINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\
set VSINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\
set WindowsSdkDir=C:\Program Files (x86)\Windows Kits\10\
set WindowsSdkVersion=10.0.26100.0
set UniversalCRTSdkDir=C:\Program Files (x86)\Windows Kits\10\
set UCRTVersion=10.0.26100.0
echo Compiling selection...
set VCINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\VC\
set VCTOOLSINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\
set VSINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\
set WindowsSdkDir=C:\Program Files (x86)\Windows Kits\10\
set WindowsSdkVersion=10.0.26100.0
set UniversalCRTSdkDir=C:\Program Files (x86)\Windows Kits\10\
set UCRTVersion=10.0.26100.0
rdmd -debug -m64 -g -gf --main -unittest -g "--eval=bool beginInvokeOnOwner;" "--eval=bool invokeRan;" "--eval=bool accessDenied;" "--eval=bool exceptionMarshaled;" "--eval=auto worker = new Thread({" "--eval=scope (exit) dispatcher.shutdown();" "--eval=dispatcher.invokeAsync({" "--eval=beginInvokeOnOwner = (Thread.getThis() is owner);" "--eval=});" "--eval=dispatcher.invoke({ invokeRan = true; });" "--eval=if (!dispatcher.checkAccess())" "--eval={" "--eval=try" "--eval=dispatcher.verifyAccess();" "--eval=catch (Exception)" "--eval=accessDenied = true;" "--eval=}" "--eval=try" "--eval=dispatcher.invoke({ throw new Exception(\"boom\"); });" "--eval=catch (Exception e)" "--eval=exceptionMarshaled = (e.msg == \"boom\");" "--eval=});" "--eval=worker.start();" "--eval=(cast(Dispatcher) dispatcher).run();" "--eval=worker.join();" "--eval=assert(beginInvokeOnOwner);" "--eval=assert(invokeRan);" "--eval=assert(accessDenied);" "--eval=assert(exceptionMarshaled);" "--eval=}" "--eval=unittest" "--eval={" "--eval=// End-to-end over the real platform loop (Win32 on Windows, the" "--eval=// portable fallback elsewhere) -- note: no version() blocks needed." "--eval=auto dispatcher = cast(shared) new Dispatcher(createPlatformEventLoop());" "--eval=int processed;" "--eval=auto worker = new Thread({" "--eval=scope (exit) dispatcher.shutdown();" "--eval=foreach (i; 0 .. 5)" "--eval=dispatcher.invokeAsync({ processed++; });" "--eval=dispatcher.invoke({ });   // FIFO barrier: all five ran before this" "--eval=});" "--eval=worker.start();" "--eval=(cast(Dispatcher) dispatcher).run();" "--eval=worker.join();" "--eval=assert(processed == 5);" "--eval=}"
:reportError
set ERR=%ERRORLEVEL%
set DISPERR=%ERR%
if %ERR% LSS -65535 set DISPERR=0x%=EXITCODE%
if %errorlevel% neq 0 echo Building  failed (error code %DISPERR%)!
if %ERR% neq 0 exit /B %ERR%
if %errorlevel% == 0 echo Compilation successful.
