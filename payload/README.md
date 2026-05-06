# Lotus setup payload

Files placed here are copied into `Windows\Setup\Lotus` inside the image. `SetupComplete.cmd` runs once after Windows setup and installs whatever payload is present.

Expected layout:

```text
payload/
  Fonts/                 MiSans .ttf/.ttc/.otf files
  DirectX/DXSETUP.exe    Extracted DirectX 9.0c redist setup
  VCRedist/              VC++ 2005-2022 redistributable .exe/.msi installers
  DotNet/                .NET 8/9 Desktop Runtime .exe installers
  PowerShell/            Latest PowerShell-*-win-*.msi
  Office2016Mondo/       ODT officedeploymenttool.exe plus configuration.xml
```

Office is installed by a first-logon scheduled task so the desktop appears before the online Office 2016 Mondo install starts.
