# PowerShell ZIP -> unofficial MSI builder (v3: cached MSI assets and WiX)

This adds one **manual GitHub Actions workflow** to a fork of `PowerShell/PowerShell`.
It wraps the official, SHA-256-verified Windows ZIP release in an unsigned MSI using
Microsoft's original PowerShell 7.6.0 WiX authoring. It does **not** compile PowerShell
or use Microsoft's signing infrastructure.

## Installation into the fork

Copy the following paths into the root of your fork's **default branch** (usually `main`):

```
.github/workflows/build-custom-msi.yml
tools/custom-msi/build-msi.ps1
```

Open **Actions > Build unofficial PowerShell MSI > Run workflow**.
If the workflow is missing, confirm that the YAML exists on the default branch
and Actions are enabled for the fork.

## GitHub Actions inputs

| Input | Choices / default | Effect |
|---|---|---|
| `version` | `7.7.0` | Exact official stable release, used in the ZIP URL |
| `architecture` | `x64` (default), `x86`, `arm64`, `all` | Each selected architecture builds as a separate job/artifact |
| `install_policy` | `block-official` (default), `upgrade-official` | Disallow or allow migrating an older official MSI of the **same architecture** |
| `microsoft_update` | `disabled` (default), `legacy-unchecked`, `legacy-checked` | Remove legacy Microsoft Update UI/action, or restore the two original checkboxes and registration action with selected initial state |
| `sha256_x64` | Official PowerShell 7.7.0 x64 checksum | ZIP verification for x64 |
| `sha256_x86` | Official PowerShell 7.7.0 x86 checksum | ZIP verification for x86 |
| `sha256_arm64` | Official PowerShell 7.7.0 ARM64 checksum | ZIP verification for ARM64 |

**Important:** For a version other than `7.7.0`, replace the relevant SHA-256 input(s)
with the hashes published on that version's official GitHub release page. The defaults
are **only** for `7.7.0`. Hash mismatches abort packaging. The workflow downloads
ZIP files directly from `https://github.com/PowerShell/PowerShell/releases/`.

## Reusing MSI sources and WiX across GitHub Actions runs

Two independent `actions/cache@v4` entries are restored before building:

| Cache key | Cached content | What happens on a cache hit |
|---|---|---|
| `powershell-7.6.0-msi-assets-windows-v1` | `legacy-powershell/assets` from the official PowerShell `v7.6.0` tag | Skip the second `actions/checkout` entirely |
| `wix-3.14.1-binaries-windows-v1` | `.build-cache/wix3141` (extracted WiX tools) | Skip downloading *and* extracting WiX |

On a miss, the workflow checks out only the upstream `assets` directory (sparse
checkout), and the build script downloads and extracts WiX to a persistent
workspace directory. Both are saved by the caching action at the end of the
successful job and can be restored by subsequent jobs/runs. The cache keys are
fixed because both upstream versions are pinned; change their `v1` suffix to
force a refresh.

The official PowerShell 7.7+ ZIP is still downloaded every build and its
user-supplied SHA-256 verified. MSI output is **not** cached, so installer-mode
and architecture input changes always generate fresh MSI packages.

GitHub's caches are not permanent and may be evicted; after eviction the next
build downloads everything again. Repositories can adjust cache retention in
**Settings → Actions → General → Cache settings**. Inspect cache entries in
**Actions → Caches**. If you run `all`, concurrent jobs may race to create the
same cache key on the first build; only one needs to save it.

## Installation modes

### Default: `block-official`

Uses independent, architecture-specific custom MSI `UpgradeCode` identities.
It checks for an existing PowerShell MSI/ZIP registry-discovery entry and refuses
to overwrite a Microsoft MSI or a registered ZIP installation. It can major-upgrade
previous custom MSI builds that use the same custom identity (including the original
v1 x64 builder).

### Opt-in: `upgrade-official` — migration build

Keeps the same independent custom MSI `UpgradeCode`, but adds a second WiX
`Upgrade` entry for Microsoft's original **same-architecture** MSI `UpgradeCode`.
The old MSI should be removed through the normal Windows Installer major-upgrade
sequence **before** the new files are installed. This is a true MSI migration,
not simply overwriting `C:\Program Files\PowerShell\7`.

The migration is limited to **older** MSI versions. It must not overwrite an equal
or newer official MSI, and a ZIP deployment without a related MSI still fails the
registration check. If an existing official installation was deployed into a custom
folder, test that behavior separately: the new installer uses the standard folder
unless its own saved install-folder setting says otherwise.

This **migration mode is an untested code path**. Test it in a VM with the official
7.6 MSI, verifying that the old product is removed from Installed Apps, the new
custom product appears, the PowerShell discovery registry key points to the new
installation, and uninstall leaves no stale files/registry entries.

## Microsoft Update options (legacy)

- `disabled` (default): removes the old MU/WSUS installer dialog, the `EnableMU`
  custom action, and the package's `MURegistryEntries` component. **It does not
  disable Windows Update, change existing WSUS policy, or unregister a Microsoft
  Update service already configured on the PC.**
- `legacy-unchecked`: copies Microsoft's 7.6 `RegisterMicrosoftUpdate.ps1` from
  `assets/MicrosoftUpdate/` and retains the original installer UI; both `USE_MU`
  and `ENABLE_MU` start **unchecked**. Users may select them at installation time.
- `legacy-checked`: same original 7.6 UI and registration action, with both
  checkboxes initially **checked**. The installer may register the system with
  Microsoft Update (a machine-wide effect). This is opt-in and not recommended
  for an unofficial 7.7 MSI.

**Neither legacy option guarantees Microsoft Update / WSUS / ConfigMgr servicing.**
Microsoft is no longer publishing an official MSI for 7.7. A checked box can register
an update preference or Microsoft Update service without Microsoft publishing any
applicable update for this MSI. Moreover, existing machine-wide policy and registry
settings may remain from the previous official MSI. For the safest default,
use `disabled`, and distribute subsequent community-built MSI upgrades yourself.

The legacy MU registration script is Microsoft's original MIT-licensed script,
not a new implementation. It is copied into the MSI payload only when selected.
The UI options are *installer settings*, not an external Windows Update blocker.

## Verify installation and migration in a Windows VM

1. Clean install on x64, x86, and ARM64 systems of the appropriate architecture.
2. Official 7.6 MSI -> `upgrade-official` custom 7.7 MSI of the **same** architecture.
3. Official 7.6 MSI -> `block-official` MSI: should **fail without changing the old install**.
4. Existing custom MSI -> newer custom MSI: should major-upgrade successfully.
5. Existing registered ZIP installation -> either MSI mode: should **fail** (unless a real related official MSI is also detected).
6. Silent installation (`msiexec /i package.msi /qn`), UI installation, repair, and uninstall.
7. Installed Apps entry, PATH, context menus, Start Menu shortcut, `pwsh.exe`, and PowerShellCore `InstalledVersions` registry metadata.
8. With `legacy-checked`, check both `UseMU` persistence and system Windows Update service enrollment, *but do not assume future updates will arrive*.
9. Verify the old MSI is removed exactly once. Use `msiexec /i package.msi /L*V install.log` if migration fails.

**Do not use the migration variant on a production installation until it has passed
these tests.** This builder is generated and source-checked, but has not been executed
on a Windows GitHub Actions runner or installation-tested in this session.

## Files and upstream source

- [PowerShell 7.6.0 Product.wxs](https://github.com/PowerShell/PowerShell/blob/v7.6.0/assets/wix/Product.wxs)
- [PowerShell 7.6.0 Microsoft Update script](https://github.com/PowerShell/PowerShell/blob/v7.6.0/assets/MicrosoftUpdate/RegisterMicrosoftUpdate.ps1)
- [PowerShell 7.7 release artifacts and SHA-256 hashes](https://github.com/PowerShell/PowerShell/releases/tag/v7.7.0)

The workflow checks out the 7.6.0 installer files as a separate checkout in the job;
there is no need to revert PowerShell's upstream MSI-removal PR or fork WiX. The
MSI files are unsigned. Microsoft-signed EXE/DLL files in the official ZIP remain unchanged.
