set PATH=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.50.35717\bin\HostX86\x86;C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE;C:\Program Files (x86)\Windows Kits\10\bin;C:\D\dmd-2.112.0\windows\bin;%PATH%
set DMD_LIB=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.50.35717\lib\x64;C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.26100.0\um\x64
set VCINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\VC\
set VCTOOLSINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.50.35717\
set VSINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\
set WindowsSdkDir=C:\Program Files (x86)\Windows Kits\10\
set WindowsSdkVersion=10.0.26100.0
set UniversalCRTSdkDir=C:\Program Files (x86)\Windows Kits\10\
set UCRTVersion=10.0.26100.0
echo Compiling selection...
set VCINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\VC\
set VCTOOLSINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.50.35717\
set VSINSTALLDIR=C:\Program Files\Microsoft Visual Studio\18\Community\
set WindowsSdkDir=C:\Program Files (x86)\Windows Kits\10\
set WindowsSdkVersion=10.0.26100.0
set UniversalCRTSdkDir=C:\Program Files (x86)\Windows Kits\10\
set UCRTVersion=10.0.26100.0
rdmd -debug -m64 -g -gf --main -unittest -g "--eval=names:"
:reportError
set ERR=%ERRORLEVEL%
set DISPERR=%ERR%
if %ERR% LSS -65535 set DISPERR=0x%=EXITCODE%
if %errorlevel% neq 0 echo Building  failed (error code %DISPERR%)!
if %ERR% neq 0 exit /B %ERR%
if %errorlevel% == 0 echo Compilation successful.
