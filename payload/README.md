# Lotus setup payload

Files placed here are copied into `Windows\Setup\Lotus` inside the image. `SetupComplete.cmd` runs once after Windows setup and installs whatever payload is present.

Expected layout:

```text
payload/
  Fonts/                 MiSans .ttf/.ttc/.otf files
  DirectX/DXSETUP.exe    Extracted DirectX 9.0c redist setup
  VCRedist/              VC++ 2008-2026 redistributable .exe/.msi installers
  DotNet/                .NET 8/9 Desktop Runtime .exe installers
  PowerShell/            Latest PowerShell-*-win-*.msi
  Office2016Mondo/       ODT officedeploymenttool.exe plus configuration.xml
  Store/                 MicrosoftStoreInstaller.exe, or Store/App Installer AppX/MSIX packages plus dependencies
  XboxInstaller/         XboxInstaller.exe, launched at first logon to restore Xbox/Gaming components
```

Office is installed by a first-logon scheduled task so the desktop appears before the online Office 2016 Mondo install starts.
If `Office2016Mondo` also contains a pre-downloaded Office source cache referenced by `configuration.xml`, the same task installs from the local cache instead of downloading at first logon.

VC++ 2005 redistributables are intentionally skipped because their legacy installers can break unattended setup on current Windows builds.

`MicrosoftStoreInstaller.exe` is launched silently during `SetupComplete` with all-users mode, then retried once in the first user session. Store AppX/MSIX packages are also provisioned during `SetupComplete` when present under `Store`, then rechecked in the first user session. Put current Microsoft Store, StorePurchaseApp, DesktopAppInstaller, VCLibs, UI.Xaml, WindowsAppRuntime, and related dependency packages there when the source image does not already include them.
