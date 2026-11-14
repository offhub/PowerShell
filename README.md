# Unofficial PowerShell 7.7 MSI builder

These two files are intended to be added to a fork of `PowerShell/PowerShell`, or to an independent GitHub repository. The workflow checks out the public **v7.6.0** source separately to reuse Microsoft's original WiX `Product.wxs` and assets. It uses the official **PowerShell 7.7.0 win-x64 ZIP** as the installed binary payload. It **does not compile PowerShell** or sign the MSI.

## Install into your fork

Copy `.github/workflows/build-custom-msi.yml` and `tools/custom-msi/build-msi.ps1` into the same paths in the root of your fork; commit and push them. Go to **Actions → Build unofficial PowerShell MSI → Run workflow**. The defaults are the version 7.7.0 and its official published SHA-256. Download the resulting `.msi` from the workflow artifacts.

The script uses WiX 3.14.1 *binaries* to compile the recovered WiX 3 installer definition. WiX 3.14.1 is a later security-maintenance release than 3.11, but the source is still WiX 3 syntax.

## What it changes from Microsoft's original MSI

- Uses an independent MSI UpgradeCode, fixed between versions of this custom package.
- Retains the conventional stable x64 PowerShell installation detection key, with an `UnofficialMSI=1` marker.
- Stops if another installation already owns the stable PowerShell registry-discovery key (the custom MSI's own upgrades are allowed).
- Removes the Microsoft Update registration action, MU UI and MU properties, as Microsoft no longer ships MSI servicing for 7.7.
- Separates remembered installer UI options from Microsoft's own MSI registry settings.
- Keeps the old installer options for PATH, shortcuts, Explorer integration, optional remoting and event manifest registration (the event manifest action is removed if the ZIP lacks its script).
- Leaves installed Microsoft-signed binaries untouched. The MSI itself remains unsigned.

## Security and compatibility limitations

This is a **source-reviewed starting implementation**, not a tested MSI build. Before distributing, run the workflow and validate its MSI on a disposable clean Windows VM: installation, ARP registration, launch, PATH, context menu and shortcuts, repair, upgrade, uninstall, and event log registration if selected. A ZIP-installed copy not tracked by the standard PowerShell registry key cannot be detected reliably by this package, so ensure `C:\Program Files\PowerShell\7` is not already owned by a different installation. Do not install over an existing Microsoft MSI.

The original `.wxs` has legacy custom actions and an installer UI; use WiX 3.14.1 because 3.11 is archived and contains older vulnerabilities. This does not give you access to Microsoft Update/WSUS servicing. Existing `.exe`/`.dll` Authenticode signatures remain, but the MSI is unsigned and must be treated as an independently authored package.

The ZIP hash defaults to the SHA-256 published with the [PowerShell 7.7.0 release](https://github.com/PowerShell/PowerShell/releases/tag/v7.7.0). For subsequent releases update both `version` and `sha256` in the workflow form.

Upstream installer implementation: [PowerShell v7.6.0 Product.wxs](https://github.com/PowerShell/PowerShell/blob/v7.6.0/assets/wix/Product.wxs). Reuse subject to Microsoft's MIT license and WiX's applicable license terms.
