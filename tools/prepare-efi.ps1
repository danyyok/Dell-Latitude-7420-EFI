param(
    [string]$Serial,
    [string]$MLB,
    [string]$UUID,
    [string]$ROM
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PlistValueNode {
    param(
        [System.Xml.XmlNode]$Dictionary,
        [string]$Key
    )

    for ($i = 0; $i -lt $Dictionary.ChildNodes.Count; $i++) {
        $candidate = $Dictionary.ChildNodes.Item($i)
        if ($candidate.NodeType -ne [System.Xml.XmlNodeType]::Element -or
            $candidate.LocalName -ne 'key' -or $candidate.InnerText -cne $Key) {
            continue
        }

        for ($j = $i + 1; $j -lt $Dictionary.ChildNodes.Count; $j++) {
            $valueNode = $Dictionary.ChildNodes.Item($j)
            if ($valueNode.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                return $valueNode
            }
        }
    }

    throw "Missing plist key: $Key"
}

function Read-Plist {
    param([string]$Path)

    $readerSettings = New-Object System.Xml.XmlReaderSettings
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $readerSettings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $readerSettings)
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $document.PreserveWhitespace = $false
    try {
        $document.Load($reader)
    }
    finally {
        $reader.Close()
    }
    return $document
}

function Save-Plist {
    param(
        [System.Xml.XmlDocument]$Document,
        [string]$Path
    )

    $writerSettings = New-Object System.Xml.XmlWriterSettings
    $writerSettings.Encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $writerSettings.Indent = $true
    $writerSettings.IndentChars = "`t"
    $writerSettings.NewLineChars = "`n"
    $writerSettings.NewLineHandling = [System.Xml.NewLineHandling]::Replace
    $temporary = "$Path.tmp"
    $writer = [System.Xml.XmlWriter]::Create($temporary, $writerSettings)
    try {
        $Document.Save($writer)
    }
    finally {
        $writer.Close()
    }
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-OpenCoreGeneric {
    param([System.Xml.XmlDocument]$Document)

    $rootDictionary = $Document.DocumentElement.SelectSingleNode('dict')
    $platformInfo = Get-PlistValueNode $rootDictionary 'PlatformInfo'
    return (Get-PlistValueNode $platformInfo 'Generic')
}

if ([string]::IsNullOrWhiteSpace($Serial) -or [string]::IsNullOrWhiteSpace($MLB)) {
    throw 'Serial and MLB must be non-empty.'
}
if ($UUID -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') {
    throw 'UUID must use the standard 8-4-4-4-12 hexadecimal format.'
}
if ($ROM -notmatch '^[0-9A-Fa-f]{12}$') {
    throw 'ROM must contain exactly 12 hexadecimal characters, without separators.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceEFI = Join-Path $repoRoot 'EFI'
$buildRoot = Join-Path $repoRoot 'build'
$outputEFI = Join-Path $buildRoot 'EFI'
if (-not (Test-Path -LiteralPath $sourceEFI -PathType Container)) {
    throw "Source EFI folder not found: $sourceEFI"
}
if (Test-Path -LiteralPath $outputEFI) {
    throw "Refusing to overwrite existing output: $outputEFI. Move it aside after backing it up, then rerun."
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$workDir = Join-Path $buildRoot ('.prepare-efi-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null

try {
    $efiWork = Join-Path $workDir 'EFI'
    New-Item -ItemType Directory -Path $efiWork | Out-Null
    Get-ChildItem -LiteralPath $sourceEFI -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $efiWork -Recurse -Force
    }

    $driverDir = Join-Path $efiWork 'OC\Drivers'
    $baseUrl = 'https://raw.githubusercontent.com/acidanthera/OcBinaryData/master/Drivers'
    $driverSpecs = @(
        @{ Name = 'HfsPlus.efi'; Hash = 'A55B5FFF36578864BA6792C4C6369C71F6F35B61DD5A853DDF8583CD36C31D8F' },
        @{ Name = 'apfs_aligned.efi'; Hash = '1663FA54103CF808B45FDA3F0385626D1F1899A9ED8258D21A827DB4426ED408' }
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($spec in $driverSpecs) {
        $download = Join-Path $driverDir $spec.Name
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$($spec.Name)" -OutFile $download
        $actualHash = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash
        if ($actualHash -ne $spec.Hash) {
            throw "SHA-256 mismatch for $($spec.Name). Refusing to use the downloaded file."
        }
    }

    $romBytes = New-Object byte[] 6
    for ($i = 0; $i -lt $romBytes.Length; $i++) {
        $romBytes[$i] = [Convert]::ToByte($ROM.Substring($i * 2, 2), 16)
    }
    $romBase64 = [Convert]::ToBase64String($romBytes)
    $profileNames = @('config.plist', 'config-recovery.plist')

    foreach ($profileName in $profileNames) {
        $configPath = Join-Path $efiWork ("OC\$profileName")
        $document = Read-Plist $configPath
        $generic = Get-OpenCoreGeneric $document

        foreach ($pair in @(
            @{ Key = 'SystemSerialNumber'; Value = $Serial },
            @{ Key = 'MLB'; Value = $MLB },
            @{ Key = 'SystemUUID'; Value = $UUID }
        )) {
            $node = Get-PlistValueNode $generic $pair.Key
            if ($node.LocalName -ne 'string') { throw "Expected string plist value for $($pair.Key) in $profileName" }
            $node.InnerText = $pair.Value
        }
        $romNode = Get-PlistValueNode $generic 'ROM'
        if ($romNode.LocalName -ne 'data') { throw "Expected data plist value for ROM in $profileName" }
        $romNode.InnerText = $romBase64

        $rootDictionary = $document.DocumentElement.SelectSingleNode('dict')
        $uefi = Get-PlistValueNode $rootDictionary 'UEFI'
        $drivers = Get-PlistValueNode $uefi 'Drivers'
        foreach ($driverName in @('HfsPlus.efi', 'apfs_aligned.efi')) {
            $matches = @()
            foreach ($entry in $drivers.ChildNodes) {
                if ($entry.NodeType -ne [System.Xml.XmlNodeType]::Element -or $entry.LocalName -ne 'dict') { continue }
                $pathNode = Get-PlistValueNode $entry 'Path'
                if ($pathNode.InnerText -ceq $driverName) { $matches += $entry }
            }
            if ($matches.Count -ne 1) { throw "Expected one $driverName entry in $profileName" }
            $enabledNode = Get-PlistValueNode $matches[0] 'Enabled'
            if ($enabledNode.LocalName -ne 'true') {
                $trueNode = $document.CreateElement('true')
                [void]$enabledNode.ParentNode.ReplaceChild($trueNode, $enabledNode)
            }
        }
        Save-Plist $document $configPath
    }

    Move-Item -LiteralPath $efiWork -Destination $outputEFI
    Write-Host "Prepared EFI: $outputEFI"
    Write-Host 'The checked-in templates are unchanged. Keep build\EFI private.'
}
finally {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
}
