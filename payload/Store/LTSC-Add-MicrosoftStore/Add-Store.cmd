@echo off
for /f "tokens=6 delims=[]. " %%G in ('ver') do if %%G lss 16299 goto :version
%windir%\system32\reg.exe query "HKU\S-1-5-19" 1>nul 2>nul || goto :uac
setlocal enableextensions
if /i "%PROCESSOR_ARCHITECTURE%" equ "AMD64" (set "arch=x64") else (set "arch=x86")
cd /d "%~dp0"

if not exist "*WindowsStore*.appxbundle" if not exist "*WindowsStore*.msixbundle" goto :nofiles
if not exist "*WindowsStore*.xml" goto :nofiles

for /f %%i in ('dir /b /o:n *WindowsStore*.appxbundle *WindowsStore*.msixbundle 2^>nul') do set "Store=%%i"
for /f %%i in ('dir /b /o:n *NET.Native.Framework*1.6*.appx 2^>nul ^| find /i "x64"') do set "Framework6X64=%%i"
for /f %%i in ('dir /b /o:n *NET.Native.Framework*1.6*.appx 2^>nul ^| find /i "x86"') do set "Framework6X86=%%i"
for /f %%i in ('dir /b /o:n *NET.Native.Runtime*1.6*.appx 2^>nul ^| find /i "x64"') do set "Runtime6X64=%%i"
for /f %%i in ('dir /b /o:n *NET.Native.Runtime*1.6*.appx 2^>nul ^| find /i "x86"') do set "Runtime6X86=%%i"
for /f %%i in ('dir /b /o:n *VCLibs*140*.appx 2^>nul ^| find /i "x64"') do set "VCLibsX64=%%i"
for /f %%i in ('dir /b /o:n *VCLibs*140*.appx 2^>nul ^| find /i "x86"') do set "VCLibsX86=%%i"
for /f %%i in ('dir /b /o:n *VCLibs*140.00.UWPDesktop*.appx 2^>nul ^| find /i "x64"') do set "VCLibsUwpX64=%%i"
for /f %%i in ('dir /b /o:n *VCLibs*140.00.UWPDesktop*.appx 2^>nul ^| find /i "x86"') do set "VCLibsUwpX86=%%i"
for /f %%i in ('dir /b /o:n *UI.Xaml.2.4*.appx 2^>nul ^| find /i "x64"') do set "Xaml24X64=%%i"
for /f %%i in ('dir /b /o:n *UI.Xaml.2.4*.appx 2^>nul ^| find /i "x86"') do set "Xaml24X86=%%i"
for /f %%i in ('dir /b /o:n *UI.Xaml.2.8*.appx 2^>nul ^| find /i "x64"') do set "Xaml28X64=%%i"
for /f %%i in ('dir /b /o:n *UI.Xaml.2.8*.appx 2^>nul ^| find /i "x86"') do set "Xaml28X86=%%i"
for /f %%i in ('dir /b /o:n *WindowsAppRuntime*.msix 2^>nul ^| find /i "x64"') do set "AppRuntimeX64=%%i"
for /f %%i in ('dir /b /o:n *WindowsAppRuntime*.msix 2^>nul ^| find /i "x86"') do set "AppRuntimeX86=%%i"

if exist "*StorePurchaseApp*.appxbundle" if exist "*StorePurchaseApp*.xml" (
for /f %%i in ('dir /b /o:n *StorePurchaseApp*.appxbundle *StorePurchaseApp*.msixbundle 2^>nul') do set "PurchaseApp=%%i"
)
if exist "*StorePurchaseApp*.msixbundle" if exist "*StorePurchaseApp*.xml" (
for /f %%i in ('dir /b /o:n *StorePurchaseApp*.appxbundle *StorePurchaseApp*.msixbundle 2^>nul') do set "PurchaseApp=%%i"
)
if exist "*DesktopAppInstaller*.appxbundle" if exist "*DesktopAppInstaller*.xml" (
for /f %%i in ('dir /b /o:n *DesktopAppInstaller*.appxbundle *DesktopAppInstaller*.msixbundle 2^>nul') do set "AppInstaller=%%i"
)
if exist "*DesktopAppInstaller*.msixbundle" if exist "*DesktopAppInstaller*.xml" (
for /f %%i in ('dir /b /o:n *DesktopAppInstaller*.appxbundle *DesktopAppInstaller*.msixbundle 2^>nul') do set "AppInstaller=%%i"
)
if exist "*XboxIdentityProvider*.appxbundle" if exist "*XboxIdentityProvider*.xml" (
for /f %%i in ('dir /b /o:n *XboxIdentityProvider*.appxbundle *XboxIdentityProvider*.msixbundle 2^>nul') do set "XboxIdentity=%%i"
)
if exist "*XboxIdentityProvider*.msixbundle" if exist "*XboxIdentityProvider*.xml" (
for /f %%i in ('dir /b /o:n *XboxIdentityProvider*.appxbundle *XboxIdentityProvider*.msixbundle 2^>nul') do set "XboxIdentity=%%i"
)
if exist "*GamingServices*.appxbundle" (
for /f %%i in ('dir /b /o:n *GamingServices*.appxbundle *GamingServices*.msixbundle 2^>nul') do set "GamingServices=%%i"
)
if exist "*XboxGamingOverlay*.appxbundle" (
for /f %%i in ('dir /b /o:n *XboxGamingOverlay*.appxbundle *XboxGamingOverlay*.msixbundle 2^>nul') do set "XboxGamingOverlay=%%i"
)
if exist "*GamingApp*.msixbundle" (
for /f %%i in ('dir /b /o:n *GamingApp*.appxbundle *GamingApp*.msixbundle 2^>nul') do set "GamingApp=%%i"
)

if /i %arch%==x64 (
set "DepLegacy=%VCLibsX64%,%VCLibsX86%,%Framework6X64%,%Framework6X86%,%Runtime6X64%,%Runtime6X86%"
set "DepModern=%VCLibsX64%,%VCLibsX86%,%VCLibsUwpX64%,%VCLibsUwpX86%,%Xaml24X64%,%Xaml24X86%,%Xaml28X64%,%Xaml28X86%,%AppRuntimeX64%,%AppRuntimeX86%"
set "DepStore=%DepLegacy%,%VCLibsUwpX64%,%VCLibsUwpX86%,%Xaml24X64%,%Xaml24X86%,%Xaml28X64%,%Xaml28X86%,%AppRuntimeX64%,%AppRuntimeX86%"
set "DepPurchase=%DepStore%"
set "DepXbox=%DepStore%"
set "DepInstaller=%VCLibsX64%,%VCLibsX86%,%VCLibsUwpX64%,%VCLibsUwpX86%,%AppRuntimeX64%,%AppRuntimeX86%"
) else (
set "DepLegacy=%VCLibsX86%,%Framework6X86%,%Runtime6X86%"
set "DepModern=%VCLibsX86%,%VCLibsUwpX86%,%Xaml24X86%,%Xaml28X86%,%AppRuntimeX86%"
set "DepStore=%DepLegacy%,%VCLibsUwpX86%,%Xaml24X86%,%Xaml28X86%,%AppRuntimeX86%"
set "DepPurchase=%DepStore%"
set "DepXbox=%DepStore%"
set "DepInstaller=%VCLibsX86%,%VCLibsUwpX86%,%AppRuntimeX86%"
)

for %%i in (%DepStore%) do (
if not exist "%%i" goto :nofiles
)

set "PScommand=PowerShell -NoLogo -NoProfile -NonInteractive -InputFormat None -ExecutionPolicy Bypass"

echo.
echo ============================================================
echo Adding Microsoft Store
echo ============================================================
echo.
1>nul 2>nul %PScommand% Add-AppxProvisionedPackage -Online -PackagePath %Store% -DependencyPackagePath %DepStore% -LicensePath Microsoft.WindowsStore_8wekyb3d8bbwe.xml
for %%i in (%DepStore%) do (
%PScommand% Add-AppxPackage -Path %%i
)
%PScommand% Add-AppxPackage -Path %Store%

if defined PurchaseApp (
echo.
echo ============================================================
echo Adding Store Purchase App
echo ============================================================
echo.
1>nul 2>nul %PScommand% Add-AppxProvisionedPackage -Online -PackagePath %PurchaseApp% -DependencyPackagePath %DepPurchase% -LicensePath Microsoft.StorePurchaseApp_8wekyb3d8bbwe.xml
%PScommand% Add-AppxPackage -Path %PurchaseApp%
)
if defined AppInstaller (
echo.
echo ============================================================
echo Adding App Installer
echo ============================================================
echo.
1>nul 2>nul %PScommand% Add-AppxProvisionedPackage -Online -PackagePath %AppInstaller% -DependencyPackagePath %DepInstaller% -LicensePath Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.xml
%PScommand% Add-AppxPackage -Path %AppInstaller%
)
if defined XboxIdentity (
echo.
echo ============================================================
echo Adding Xbox Identity Provider
echo ============================================================
echo.
1>nul 2>nul %PScommand% Add-AppxProvisionedPackage -Online -PackagePath %XboxIdentity% -DependencyPackagePath %DepXbox% -LicensePath Microsoft.XboxIdentityProvider_8wekyb3d8bbwe.xml
%PScommand% Add-AppxPackage -Path %XboxIdentity%
)
if defined GamingServices (
echo.
echo ============================================================
echo Adding Gaming Services
echo ============================================================
echo.
1>nul 2>nul %PScommand% Add-AppxProvisionedPackage -Online -PackagePath %GamingServices% -DependencyPackagePath %DepModern% -SkipLicense
%PScommand% Add-AppxPackage -Path %GamingServices%
)
if defined XboxGamingOverlay (
echo.
echo ============================================================
echo Adding Xbox Game Bar
echo ============================================================
echo.
1>nul 2>nul %PScommand% Add-AppxProvisionedPackage -Online -PackagePath %XboxGamingOverlay% -DependencyPackagePath %DepModern% -SkipLicense
%PScommand% Add-AppxPackage -Path %XboxGamingOverlay%
)
if defined GamingApp (
echo.
echo ============================================================
echo Adding Xbox App
echo ============================================================
echo.
1>nul 2>nul %PScommand% Add-AppxProvisionedPackage -Online -PackagePath %GamingApp% -DependencyPackagePath %DepModern% -SkipLicense
%PScommand% Add-AppxPackage -Path %GamingApp%
)
goto :fin

:uac
echo.
echo ============================================================
echo Error: Run the script as administrator
echo ============================================================
echo.
echo.
echo Press any key to Exit
pause >nul
exit

:version
echo.
echo ============================================================
echo Error: This pack is for Windows 10 version 1709 and later
echo ============================================================
echo.
echo.
echo Press any key to Exit
pause >nul
exit

:nofiles
echo.
echo ============================================================
echo Error: Required files are missing in the current directory
echo ============================================================
echo.
echo.
echo Press any key to Exit
pause >nul
exit

:fin
echo.
echo ============================================================
echo Done
echo ============================================================
echo.
echo Press any Key to Exit.
pause >nul
exit
