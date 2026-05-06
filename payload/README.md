# Lotus setup payload

Files placed here are copied into `Windows\Setup\Lotus` inside the image. `SetupComplete.cmd` runs once after Windows setup and installs whatever payload is present.

Expected layout:

```text
payload/
  Fonts/                 MiSans .ttf/.ttc/.otf files
  DirectX/DXSETUP.exe    Extracted DirectX 9.0c redist setup
  VCRedist/              VC++ 2005-2022 redistributable .exe/.msi installers
  PowerShell/            Latest PowerShell-*-win-*.msi
  Office2016Mondo/       Office setup.exe plus configuration.xml
  Activation/            Optional legal activation hook
```

`Activation/Activate-Legal.cmd` is intentionally not provided. Put only your own legitimate activation commands there, for example `slmgr` with a valid key or an authorized KMS endpoint.
