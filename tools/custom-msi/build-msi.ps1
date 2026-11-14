# Build an unofficial x64 MSI using PowerShell v7.6.0's Product.wxs
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
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A fixed custom MSI UpgradeCode, different from Microsoft's original x64 MSI.
# Keep this unchanged for subsequent custom MSI releases.
$customUpgradeCode = 'b7bfda8e-3029-4931-982d-6a4218e1b5c6'
$originalDiscoveryId = '31ab5147-9a97-4452-8443-d9709f0516e1'
$discoveryKey = "Software\Microsoft\PowerShellCore\InstalledVersions\$originalDiscoveryId"

$LegacyRoot = (Resolve-Path -LiteralPath $LegacyRoot).Path
$originalWxs = Join-Path $LegacyRoot 'assets/wix/Product.wxs'
if (-not (Test-Path -LiteralPath $originalWxs)) {
    throw "PowerShell 7.6 Product.wxs not found: $originalWxs"
}

$work = Join-Path ([IO.Path]::GetTempPath()) 'powershell-custom-msi'
if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
}
New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$zipName = "PowerShell-$Version-win-x64.zip"
$zipPath = Join-Path $work $zipName
$zipUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$Version/$zipName"
Write-Host "Downloading $zipUrl"
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
$actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
if ($actualHash -ine $ExpectedSha256) {
    throw "ZIP SHA-256 mismatch. Expected $ExpectedSha256, found $actualHash."
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
$wixDir = Join-Path $work 'wix'
Write-Host "Downloading WiX 3 binaries: $wixUrl"
Invoke-WebRequest -Uri $wixUrl -OutFile $wixZip
Expand-Archive -LiteralPath $wixZip -DestinationPath $wixDir
$heatFile = Get-ChildItem -LiteralPath $wixDir -Filter 'heat.exe' -File -Recurse | Select-Object -First 1
if (-not $heatFile) { throw 'WiX heat.exe was not found.' }
$wixBin = $heatFile.DirectoryName
$heat = Join-Path $wixBin 'heat.exe'
$candle = Join-Path $wixBin 'candle.exe'
$light = Join-Path $wixBin 'light.exe'
foreach ($item in @($heat, $candle, $light)) {
    if (-not (Test-Path -LiteralPath $item)) { throw "Missing WiX executable: $item" }
}

# Patch a *copy* of the 7.6 original; never edit Microsoft's source tree.
# Keep original WiX UI, shortcut, context menu and PATH authoring.
$wxs = Join-Path $work 'Product.wxs'
$source = Get-Content -LiteralPath $originalWxs -Raw
$oldDefinition = '<?define UpgradeCodeRelease = "31ab5147-9a97-4452-8443-d9709f0516e1"?>'
$newDefinition = "<?define UpgradeCodeRelease = `"$customUpgradeCode`"?>"
if (-not $source.Contains($oldDefinition)) { throw 'Original UpgradeCode definition changed.' }
$source = $source.Replace($oldDefinition, $newDefinition)
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

# The 7.7 ZIP no longer ships RegisterMicrosoftUpdate.ps1.
# Remove both the obsolete servicing custom action and its configuration UI.
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

# Avoid overwriting an official MSI or existing ZIP registration. Allows upgrades
# of prior builds made by this script, identifiable by UnofficialMSI=1.
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
$condition = New-WixElement 'Condition'
$condition.SetAttribute('Message', 'Remove the existing official PowerShell MSI or ZIP registration before installing this independently packaged MSI.')
$condition.InnerText = 'Installed OR NOT EXISTING_PS_INSTALL OR EXISTING_CUSTOM_MSI'
[void] $product.AppendChild($condition)

# Save with UTF-8 without BOM; WiX can consume an ordinary .wxs file.
[System.IO.File]::WriteAllText($wxs, $doc.OuterXml, [System.Text.UTF8Encoding]::new($false))

# Use the original heat/candle/light flow, bypassing the stale 7.6 BOM.
$fragment = Join-Path $work 'Fragment.wxs'
$objects = Join-Path $work 'obj'
New-Item -ItemType Directory -Path $objects -Force | Out-Null
$msiName = "PowerShell-$Version-win-x64-unofficial.msi"
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
    '-dProductProgFilesDir=ProgramFiles64Folder',
    '-dFileArchitecture=amd64',
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
    Invoke-Tool $candle (@($wxs, $fragment, '-arch', 'x64', '-out', "$objects\") + $extensions + $defines)
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
