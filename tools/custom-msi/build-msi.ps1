# Build an unofficial Windows MSI using PowerShell v7.6.0's Product.wxs
# and the official PowerShell stable release ZIP. No compilation or signing.
# Copyright: original WiX authoring is (c) Microsoft, MIT License.
# This script is independently authored.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string] $ExpectedSha256,

    [Parameter(Mandatory)]
    [string] $LegacyRoot,

    [Parameter(Mandatory)]
    [string] $OutputDirectory,

    # Persistent runner workspace path restored/saved via actions/cache.
    [Parameter(Mandatory)]
    [string] $WixCacheDirectory,

    # Version/architecture-specific official release ZIP restored via actions/cache.
    [Parameter(Mandatory)]
    [string] $ReleaseZipCacheDirectory,

    [ValidateSet('x64', 'x86', 'arm64')]
    [string] $Architecture = 'x64',

    [ValidateSet('block-official', 'upgrade-official')]
    [string] $InstallPolicy = 'block-official',

    [ValidateSet('disabled', 'legacy-unchecked', 'legacy-checked')]
    [string] $MicrosoftUpdate = 'disabled'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Independent, stable MSI upgrade identities: keep unchanged across custom releases.
# Different from the official MSI identities, which are used ONLY for optional migration.
$architectures = @{
    x64 = @{
        CustomUpgradeCode = 'b7bfda8e-3029-4931-982d-6a4218e1b5c6'
        OfficialUpgradeCode = '31ab5147-9a97-4452-8443-d9709f0516e1'
        FileArchitecture = 'amd64'
        ProgramFilesDirectory = 'ProgramFiles64Folder'
    }
    x86 = @{
        CustomUpgradeCode = 'c4aa87a8-d562-48e4-aa9b-197c7932375e'
        OfficialUpgradeCode = '1d00683b-0f84-4db8-a64f-2f98ad42fe06'
        FileArchitecture = 'x86'
        ProgramFilesDirectory = 'ProgramFilesFolder'
    }
    arm64 = @{
        CustomUpgradeCode = 'e5ccda2e-1568-4ec8-b6a4-3814d86e2f5d'
        OfficialUpgradeCode = '75c68ab2-09d8-46b8-b697-d829bdd4c94f'
        FileArchitecture = 'arm64'
        ProgramFilesDirectory = 'ProgramFiles64Folder'
    }
}
$config = $architectures[$Architecture]
$customUpgradeCode = $config.CustomUpgradeCode
$originalDiscoveryId = $config.OfficialUpgradeCode
$discoveryKey = "Software\Microsoft\PowerShellCore\InstalledVersions\$originalDiscoveryId"
Write-Host "Target: PowerShell $Version $Architecture; install policy: $InstallPolicy; MU: $MicrosoftUpdate"

$LegacyRoot = (Resolve-Path -LiteralPath $LegacyRoot).Path
$originalWxs = Join-Path $LegacyRoot 'assets/wix/Product.wxs'
if (-not (Test-Path -LiteralPath $originalWxs)) {
    throw "PowerShell 7.6 Product.wxs not found: $originalWxs"
}

$work = Join-Path ([IO.Path]::GetTempPath()) "powershell-custom-msi-$Architecture"
if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
}
New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$zipName = "PowerShell-$Version-win-$Architecture.zip"
$releaseZipCache = [IO.Path]::GetFullPath($ReleaseZipCacheDirectory)
New-Item -ItemType Directory -Path $releaseZipCache -Force | Out-Null
$zipPath = Join-Path $releaseZipCache $zipName
$zipUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$Version/$zipName"
if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
    Write-Host "Using cached official ZIP: $zipPath"
}
else {
    # Download into the disposable work directory. Publish to the cache path
    # only after verifying the official expected SHA-256.
    $downloadPath = Join-Path $work $zipName
    Write-Host "Downloading $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $downloadPath
    $downloadHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
    if ($downloadHash -ine $ExpectedSha256) {
        throw "Downloaded ZIP SHA-256 mismatch. Expected $ExpectedSha256, found $downloadHash."
    }
    Move-Item -LiteralPath $downloadPath -Destination $zipPath
}
# Always reverify—even when actions/cache restored the ZIP successfully.
$actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
if ($actualHash -ine $ExpectedSha256) {
    throw "Cached ZIP SHA-256 mismatch. Expected $ExpectedSha256, found $actualHash. Clear the cache and retry."
}
Write-Host "Official ZIP SHA-256 verified: $actualHash"

$payload = Join-Path $work 'payload'
Expand-Archive -LiteralPath $zipPath -DestinationPath $payload
if (-not (Test-Path -LiteralPath (Join-Path $payload 'pwsh.exe'))) {
    throw 'ZIP payload has no pwsh.exe in its root.'
}

# Microsoft's old New-MSIPackage also staged installer icons into its payload.
$payloadAssets = Join-Path $payload 'assets'
New-Item -ItemType Directory -Path $payloadAssets -Force | Out-Null
Copy-Item -Path (Join-Path $LegacyRoot 'assets/*.ico') -Destination $payloadAssets -Force

# Use WiX 3.14.1 (the last maintained WiX 3 release) with the WiX 3 XML sources.
# The ZIP is extracted rather than run as an installer.
$wixRelease = 'wix3141rtm'
$wixName = 'wix314-binaries.zip'
$wixUrl = "https://github.com/wixtoolset/wix3/releases/download/$wixRelease/$wixName"
$wixZip = Join-Path $work $wixName
$wixDir = [IO.Path]::GetFullPath($WixCacheDirectory)

function Find-WixBin([string] $Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $null
    }
    foreach ($candidate in @(Get-ChildItem -LiteralPath $Directory -Filter 'heat.exe' -File -Recurse)) {
        $bin = $candidate.DirectoryName
        if ((Test-Path -LiteralPath (Join-Path $bin 'candle.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $bin 'light.exe') -PathType Leaf)) {
            return $bin
        }
    }
    return $null
}

$wixBin = Find-WixBin $wixDir
if ($null -eq $wixBin) {
    Write-Host "WiX cache missing or incomplete; downloading: $wixUrl"
    Invoke-WebRequest -Uri $wixUrl -OutFile $wixZip
    # Do not retain a partial toolchain from a failed prior extraction.
    if (Test-Path -LiteralPath $wixDir) {
        Remove-Item -LiteralPath $wixDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $wixZip -DestinationPath $wixDir
    $wixBin = Find-WixBin $wixDir
    if ($null -eq $wixBin) {
        throw 'WiX extraction failed: heat.exe, candle.exe, and light.exe are required.'
    }
}
else {
    Write-Host "Using cached WiX 3.14.1 toolchain: $wixBin"
}
$heat = Join-Path $wixBin 'heat.exe'
$candle = Join-Path $wixBin 'candle.exe'
$light = Join-Path $wixBin 'light.exe'

# Patch a *copy* of the 7.6 original; never edit Microsoft's source tree.
# Keep original WiX UI, shortcut, context menu and PATH authoring.
$wxs = Join-Path $work 'Product.wxs'
$source = Get-Content -LiteralPath $originalWxs -Raw
# Patch all 3 architecture branches, preserving their distinct UpgradeCodes.
# The official codes continue to be used for registry discovery and optional migration.
foreach ($entry in $architectures.GetEnumerator()) {
    $oldDefinition = '<?define UpgradeCodeRelease = "' + $entry.Value.OfficialUpgradeCode + '"?>'
    $newDefinition = '<?define UpgradeCodeRelease = "' + $entry.Value.CustomUpgradeCode + '"?>'
    if (-not $source.Contains($oldDefinition)) {
        throw "Original $($entry.Key) UpgradeCode definition changed."
    }
    $source = $source.Replace($oldDefinition, $newDefinition)
}
$source = $source.Replace('Manufacturer="Microsoft Corporation"', 'Manufacturer="Community PowerShell MSI Packager"')
$source = $source.Replace('Name="PowerShell $(var.SimpleProductVersion)-$(sys.BUILDARCH)"',
                          'Name="PowerShell $(var.SimpleProductVersion)-$(sys.BUILDARCH) (Unofficial MSI)"')
$source = $source.Replace('Software\Microsoft\PowerShellCore\InstallerProperties',
                          'Software\UnofficialPowerShellMSI\InstallerProperties')
# The stable PowerShell discovery key is not the same as our MSI UpgradeCode.
$source = $source.Replace('Key="Software\Microsoft\PowerShellCore\InstalledVersions\$(var.UpgradeCode)"',
                          "Key=`"$discoveryKey`"")

# This is valid XML even though WiX uses XML processing instructions (<?define?>).
[xml] $doc = $source
$ns = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
$ns.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')

function Remove-WixNode([string] $XPath) {
    $nodes = @($doc.SelectNodes($XPath, $ns))
    foreach ($node in $nodes) { [void] $node.ParentNode.RemoveChild($node) }
}
function New-WixElement([string] $Name) {
    return $doc.CreateElement($Name, 'http://schemas.microsoft.com/wix/2006/wi')
}

# Legacy option is explicitly opt-in: restoring the original checkboxes does not
# make Microsoft publish servicing updates for a repackaged PowerShell 7.7 MSI.
if ($MicrosoftUpdate -eq 'disabled') {
    # 7.7 no longer ships RegisterMicrosoftUpdate.ps1. Remove the obsolete action/UI.
    Remove-WixNode '//w:Property[@Id="PREVIOUS_USE_MU" or @Id="PREVIOUS_ENABLE_MU"]'
    Remove-WixNode '//w:SetProperty[@Id="USE_MU" or @Id="ENABLE_MU" or @Id="EnableMU"]'
    Remove-WixNode '//w:CustomAction[@Id="EnableMU"]'
    Remove-WixNode '//w:Custom[@Action="EnableMU"]'
    Remove-WixNode '//w:ComponentRef[@Id="MURegistryEntries"]'
    Remove-WixNode '//w:Component[@Id="MURegistryEntries"]'
    Remove-WixNode '//w:RegistryValue[@Name="UseMU" or @Name="EnableMU"]'

    $muDialog = $doc.SelectSingleNode('//w:Dialog[@Id="MuDialog"]', $ns)
    if (-not $muDialog) { throw 'Expected original Microsoft Update dialog is missing.' }
    $muFragment = $muDialog.ParentNode.ParentNode
    if ($muFragment.LocalName -ne 'Fragment') { throw 'Unexpected Microsoft Update dialog layout.' }
    [void] $muFragment.ParentNode.RemoveChild($muFragment)

    $next = $doc.SelectSingleNode('//w:Publish[@Dialog="ExplorerContextMenuDialog" and @Control="Next" and @Value="MuDialog"]', $ns)
    $back = $doc.SelectSingleNode('//w:Publish[@Dialog="VerifyReadyDlg" and @Control="Back" and @Value="MuDialog"]', $ns)
    if (-not $next -or -not $back) { throw 'Original installer UI navigation changed.' }
    $next.SetAttribute('Value', 'VerifyReadyDlg')
    $back.SetAttribute('Value', 'ExplorerContextMenuDialog')
    Remove-WixNode '//w:Publish[@Dialog="MuDialog"]'

    # Remove legacy saved-state values so an old opt-in is not presented as ours.
    Remove-WixNode '//w:Component[@Id="SaveInstallerProperties"]/w:RegistryValue[@Name="UseMU" or @Name="EnableMU"]'
}
else {
    $legacyMuScript = Join-Path $LegacyRoot 'assets/MicrosoftUpdate/RegisterMicrosoftUpdate.ps1'
    if (-not (Test-Path -LiteralPath $legacyMuScript)) {
        throw "Legacy MU registration script missing: $legacyMuScript"
    }
    if (Test-Path -LiteralPath (Join-Path $payload 'RegisterMicrosoftUpdate.ps1')) {
        throw '7.7 ZIP unexpectedly contains RegisterMicrosoftUpdate.ps1; re-review before overwriting.'
    }
    Copy-Item -LiteralPath $legacyMuScript -Destination (Join-Path $payload 'RegisterMicrosoftUpdate.ps1')

    # These are the two original 7.6 checkbox defaults (1 = initially selected).
    $defaultValue = if ($MicrosoftUpdate -eq 'legacy-checked') { '1' } else { '0' }
    foreach ($action in @('UseMU_SetDefault', 'EnableMU_SetDefault')) {
        $node = $doc.SelectSingleNode('//w:SetProperty[@Action="' + $action + '"]', $ns)
        if (-not $node) { throw "Expected $action default-setting action was not found." }
        $node.SetAttribute('Value', $defaultValue)
    }
    Write-Warning 'Legacy MU checkboxes are enabled. Registration does not guarantee updates for unofficial PowerShell 7.7 MSI releases.'
}

# Optionally remove the event-manifest custom action if the 7.7 ZIP omits it.
if (-not (Test-Path -LiteralPath (Join-Path $payload 'RegisterManifest.ps1'))) {
    Write-Warning 'RegisterManifest.ps1 absent: disabling event manifest installation option.'
    Remove-WixNode '//w:Property[@Id="PREVIOUS_REGISTER_MANIFEST"]'
    Remove-WixNode '//w:SetProperty[@Id="REGISTER_MANIFEST" or @Id="RegisterManifest"]'
    Remove-WixNode '//w:CustomAction[@Id="RegisterManifest"]'
    Remove-WixNode '//w:Custom[@Action="RegisterManifest"]'
    Remove-WixNode '//w:RegistryValue[@Name="RegisterManifest"]'
    Remove-WixNode '//w:Control[@Id="RegisterManifestCheckBox"]'
}

# Retain standard PowerShell discovery metadata but mark this package as custom.
$registry = $doc.SelectSingleNode('//w:Component[@Id="RegistryEntries"]/w:RegistryKey', $ns)
if (-not $registry) { throw 'Expected RegistryEntries component is missing.' }
$marker = New-WixElement 'RegistryValue'
$marker.SetAttribute('Type', 'integer')
$marker.SetAttribute('Name', 'UnofficialMSI')
$marker.SetAttribute('Value', '1')
[void] $registry.AppendChild($marker)

# Do not overwrite an unrelated ZIP deployment. Normal MSI major upgrades of
# our previous packages are allowed through the custom UpgradeCode.
# The explicit opt-in mode additionally detects/removes a lower-version official
# MSI through the official UpgradeCode (but retains the independent custom code).
$product = $doc.SelectSingleNode('//w:Product', $ns)
foreach ($entry in @(
    @{ Id = 'EXISTING_PS_INSTALL'; Name = 'InstallLocation'; SearchId = 'FindExistingPSInstall' },
    @{ Id = 'EXISTING_CUSTOM_MSI'; Name = 'UnofficialMSI'; SearchId = 'FindCustomMSI' }
)) {
    $property = New-WixElement 'Property'
    $property.SetAttribute('Id', $entry.Id)
    $search = New-WixElement 'RegistrySearch'
    $search.SetAttribute('Id', $entry.SearchId)
    $search.SetAttribute('Root', 'HKLM')
    $search.SetAttribute('Key', $discoveryKey)
    $search.SetAttribute('Name', $entry.Name)
    $search.SetAttribute('Type', 'raw')
    [void] $property.AppendChild($search)
    [void] $product.AppendChild($property)
}
if ($InstallPolicy -eq 'upgrade-official') {
    # WiX MajorUpgrade already schedules RemoveExistingProducts early. An additional
    # Upgrade row opts the old Microsoft MSI into that same removal operation.
    # Maximum excludes equal/newer installed versions; this is not a downgrade path.
    $major = $doc.SelectSingleNode('//w:MajorUpgrade', $ns)
    if (-not $major) { throw 'Expected WiX MajorUpgrade was not found.' }
    $major.SetAttribute('Schedule', 'afterInstallValidate')
    $upgrade = New-WixElement 'Upgrade'
    $upgrade.SetAttribute('Id', $originalDiscoveryId)
    $upgradeVersion = New-WixElement 'UpgradeVersion'
    $upgradeVersion.SetAttribute('Minimum', '0.0.0')
    $upgradeVersion.SetAttribute('IncludeMinimum', 'yes')
    $upgradeVersion.SetAttribute('Maximum', $Version)
    $upgradeVersion.SetAttribute('IncludeMaximum', 'no')
    $upgradeVersion.SetAttribute('Property', 'OFFICIAL_PS_UPGRADE')
    $upgradeVersion.SetAttribute('MigrateFeatures', 'yes')
    [void] $upgrade.AppendChild($upgradeVersion)
    [void] $product.AppendChild($upgrade)
}
$condition = New-WixElement 'Condition'
$condition.SetAttribute('Message', 'PowerShell already uses this installation registration. Use an upgrade-official build to migrate a lower-version official MSI; ZIP deployments and newer official MSIs are blocked.')
$condition.InnerText = if ($InstallPolicy -eq 'upgrade-official') {
    'Installed OR NOT EXISTING_PS_INSTALL OR EXISTING_CUSTOM_MSI OR OFFICIAL_PS_UPGRADE'
} else {
    'Installed OR NOT EXISTING_PS_INSTALL OR EXISTING_CUSTOM_MSI'
}
[void] $product.AppendChild($condition)

# Save with UTF-8 without BOM; WiX can consume an ordinary .wxs file.
[System.IO.File]::WriteAllText($wxs, $doc.OuterXml, [System.Text.UTF8Encoding]::new($false))

# Use the original heat/candle/light flow, bypassing the stale 7.6 BOM.
$fragment = Join-Path $work 'Fragment.wxs'
$objects = Join-Path $work 'obj'
New-Item -ItemType Directory -Path $objects -Force | Out-Null
$msiName = "PowerShell-$Version-win-$Architecture-$InstallPolicy-$MicrosoftUpdate-unofficial.msi"
$msi = Join-Path $OutputDirectory $msiName

function Invoke-Tool([string] $Executable, [string[]] $Arguments) {
    Write-Host "Running: $([IO.Path]::GetFileName($Executable))"
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Tool $Executable exited with code $LASTEXITCODE"
    }
}

$defines = @(
    "-dProductSourcePath=$payload",
    '-dProductName=PowerShell',
    "-dProductVersion=$Version",
    '-dSimpleProductVersion=7',
    "-dProductSemanticVersion=$Version",
    "-dProductVersionWithName=PowerShell_$Version",
    "-dProductProgFilesDir=$($config.ProgramFilesDirectory)",
    "-dFileArchitecture=$($config.FileArchitecture)",
    '-dIsPreview=False'
)
$extensions = @('-ext', 'WixUIExtension', '-ext', 'WixUtilExtension', '-ext', 'WixBalExtension')

Push-Location $LegacyRoot
try {
    Invoke-Tool $heat @(
        'dir', $payload, '-dr', 'VersionFolder', '-cg', 'ApplicationFiles',
        '-ag', '-sfrag', '-srd', '-scom', '-sreg',
        '-out', $fragment, '-var', 'var.ProductSourcePath'
    )
    Invoke-Tool $candle (@($wxs, $fragment, '-arch', $Architecture, '-out', "$objects\") + $extensions + $defines)
    $wixObjects = @(
        (Join-Path $objects 'Product.wixobj'),
        (Join-Path $objects 'Fragment.wixobj')
    )
    foreach ($obj in $wixObjects) {
        if (-not (Test-Path -LiteralPath $obj)) { throw "Missing WiX object: $obj" }
    }
    Invoke-Tool $light (@(
        '-sice:ICE61', '-sice:ICE40', '-sice:ICE57',
        '-b', $LegacyRoot, '-out', $msi, '-pdbout', (Join-Path $work 'Product.wixpdb')
    ) + $wixObjects + $extensions)
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $msi)) { throw 'WiX completed without creating an MSI.' }
$msiHash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
[IO.File]::WriteAllText("$msi.sha256", "$msiHash  $msiName`n", [Text.UTF8Encoding]::new($false))
Write-Host "Created unsigned MSI: $msi"
Write-Host "MSI SHA-256: $msiHash"
