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
  Store/                 Store/App Installer AppX/MSIX packages plus dependencies
  Store/LTSC-Add-MicrosoftStore/
                         kkkgo/LTSC-Add-MicrosoftStore package for Store, Purchase App, App Installer, and Xbox Identity
  XboxInstaller/         XboxInstaller.exe, launched at first logon to restore Xbox/Gaming components
```

Office is intentionally not bundled. Install it later with Office Tool Plus or another preferred Office installer after Windows reaches the desktop.

VC++ 2005 redistributables are intentionally skipped because their legacy installers can break unattended setup on current Windows builds.

When `Store/LTSC-Add-MicrosoftStore/Add-Store.cmd` and its AppX/XML files are present, that package is used first to restore Microsoft Store, StorePurchaseApp, DesktopAppInstaller, and XboxIdentityProvider. `MicrosoftStoreInstaller.exe` is only used as a fallback when the LTSC package is missing. Store AppX/MSIX packages are also rechecked in the first user session before XboxInstaller is launched.
