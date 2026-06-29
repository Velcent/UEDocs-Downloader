[CmdletBinding()]
param(
    [string]$InputPath = '',
    [switch]$WhatIf,
    [switch]$NoTsvUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot 'mhtml'
}

$InputPath = [System.IO.Path]::GetFullPath($InputPath)
if (-not (Test-Path -LiteralPath $InputPath -PathType Container)) {
    throw "Folder tidak ditemukan: $InputPath"
}

function Test-HtmlEntity {
    param([string]$Entity)

    if ([string]::IsNullOrEmpty($Entity)) {
        return $false
    }

    if ($Entity -match '^&#(?:\d+|x[0-9A-Fa-f]+);$') {
        return $true
    }

    return ([System.Net.WebUtility]::HtmlDecode($Entity) -ne $Entity)
}

function ConvertTo-NewEntityName {
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) {
        return $Name
    }

    $entityPattern = [regex]'&(?:#\d+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);'
    $builder = [System.Text.StringBuilder]::new()
    $index = 0

    while ($index -lt $Name.Length) {
        $char = $Name[$index]

        if ($char -eq '&') {
            $match = $entityPattern.Match($Name, $index)
            if ($match.Success -and $match.Index -eq $index -and (Test-HtmlEntity -Entity $match.Value)) {
                if ($match.Value -match '^&#(?:\d+|x[0-9A-Fa-f]+);$') {
                    [void]$builder.Append($match.Value.Substring(0, $match.Value.Length - 1))
                    [void]$builder.Append('_')
                }
                else {
                    [void]$builder.Append($match.Value)
                }

                $index += $match.Value.Length
                continue
            }
        }

        if ($char -eq ';') {
            [void]$builder.Append('&#59_')
        }
        else {
            [void]$builder.Append($char)
        }

        $index++
    }

    return $builder.ToString()
}

function ConvertTo-SafeSegment {
    param(
        [string]$Value,
        [int]$MaxLength = 90
    )

    $text = [System.Net.WebUtility]::HtmlDecode([string]$Value)
    try {
        $text = [System.Uri]::UnescapeDataString($text)
    }
    catch {
    }

    $text = ($text -replace '\s+', ' ').Trim()
    $invalidChars = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        [void]$invalidChars.Add([int][char]$char)
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($char in $text.ToCharArray()) {
        $code = [int][char]$char
        if ($invalidChars.Contains($code) -or $code -lt 32 -or $char -eq ';') {
            [void]$builder.Append("&#$code`_")
        }
        else {
            [void]$builder.Append($char)
        }
    }

    $text = $builder.ToString().Trim(' ', '.')
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = '_'
    }

    if ($text -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $text = "_$text"
    }

    if ($text.Length -gt $MaxLength) {
        $sha1 = [System.Security.Cryptography.SHA1]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
            $hash = (($sha1.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
            $prefixLength = [Math]::Max(1, $MaxLength - 9)
            $text = "$($text.Substring(0, $prefixLength).TrimEnd(' ', '.'))-$hash"
        }
        finally {
            $sha1.Dispose()
        }
    }

    return $text
}

function ConvertTo-NewEntityPathValue {
    param([string]$PathValue)

    if ([string]::IsNullOrEmpty($PathValue)) {
        return $PathValue
    }

    $parts = [regex]::Split($PathValue, '([\\/])')
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -eq '\' -or $parts[$i] -eq '/') {
            continue
        }

        $parts[$i] = ConvertTo-NewEntityName -Name $parts[$i]
    }

    return ($parts -join '')
}

function Get-RelativePathFromBase {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseUri = [Uri](([System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'))
    $fullUri = [Uri]([System.IO.Path]::GetFullPath($FullPath))
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString()) -replace '/', '\'
}

function Backup-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $backupPath = "$Path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function ConvertTo-TsvValue {
    param([string]$Value)

    return ([string]$Value -replace "`t", ' ' -replace "\r?\n", ' ').Trim()
}

function Update-TsvFiles {
    if ($NoTsvUpdate) {
        return 0
    }

    $updatedFileCount = 0
    $entityFixPath = [System.IO.Path]::GetFullPath((Join-Path $InputPath 'entity-fix.tsv'))
    $tsvFiles = @(Get-ChildItem -LiteralPath $InputPath -File -Filter '*.tsv' |
        Where-Object { -not ([System.IO.Path]::GetFullPath($_.FullName)).Equals($entityFixPath, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object FullName)

    foreach ($tsv in $tsvFiles) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]](Get-Content -LiteralPath $tsv.FullName))
        if ($lines.Count -eq 0) {
            continue
        }

        $header = [string]$lines[0]
        $columns = $header -split "`t"
        $fileIndex = [Array]::IndexOf($columns, 'file')
        $titleIndex = [Array]::IndexOf($columns, 'title')
        $saveFolderIndex = [Array]::IndexOf($columns, 'save_folder')
        $childFolderIndex = [Array]::IndexOf($columns, 'child_folder')

        $isListTsv = ($fileIndex -ge 0 -and $titleIndex -ge 0)
        $isLinkTsv = ($saveFolderIndex -ge 0 -and $childFolderIndex -ge 0)
        if (-not $isListTsv -and -not $isLinkTsv) {
            continue
        }

        $newLines = [System.Collections.Generic.List[string]]::new()
        $newLines.Add($header) | Out-Null
        $changedRows = 0

        foreach ($line in @($lines | Select-Object -Skip 1)) {
            if ([string]::IsNullOrEmpty($line)) {
                $newLines.Add($line) | Out-Null
                continue
            }

            $parts = [string]$line -split "`t", $columns.Count
            if ($parts.Count -lt $columns.Count) {
                $newLines.Add($line) | Out-Null
                continue
            }

            $oldLine = ($parts -join "`t")

            if ($isLinkTsv) {
                foreach ($index in @($saveFolderIndex, $childFolderIndex)) {
                    if ($index -ge 0 -and $index -lt $parts.Count) {
                        $parts[$index] = ConvertTo-NewEntityPathValue -PathValue ([string]$parts[$index])
                    }
                }
            }

            if ($isListTsv -and -not [string]::IsNullOrWhiteSpace([string]$parts[$titleIndex]) -and -not [string]::IsNullOrWhiteSpace([string]$parts[$fileIndex])) {
                $fileValue = [string]$parts[$fileIndex]
                $directory = ''
                $separator = '\'
                $lastSlash = [Math]::Max($fileValue.LastIndexOf('\'), $fileValue.LastIndexOf('/'))
                if ($lastSlash -ge 0) {
                    $directory = $fileValue.Substring(0, $lastSlash)
                    $separator = $fileValue.Substring($lastSlash, 1)
                }

                $directory = ConvertTo-NewEntityPathValue -PathValue $directory
                $newFileName = "$(ConvertTo-SafeSegment -Value ([string]$parts[$titleIndex]) -MaxLength 120).mhtml"
                if ($directory) {
                    $parts[$fileIndex] = "$directory$separator$newFileName"
                }
                else {
                    $parts[$fileIndex] = $newFileName
                }
            }

            $newLine = ($parts -join "`t")
            if ($newLine -ne $oldLine) {
                $changedRows++
            }

            $newLines.Add($newLine) | Out-Null
        }

        if ($changedRows -eq 0) {
            continue
        }

        $updatedFileCount++
        Write-Host "Update TSV siap: $($tsv.FullName) ($changedRows row)"
        if ($WhatIf) {
            Write-Host "DRY RUN: update TSV $($tsv.FullName)"
            continue
        }

        $backupPath = Backup-File -Path $tsv.FullName
        if ($backupPath) {
            Write-Host "Backup TSV: $backupPath"
        }

        [System.IO.File]::WriteAllLines($tsv.FullName, $newLines, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Update TSV: $($tsv.FullName)"
    }

    return $updatedFileCount
}

function Write-RenameLog {
    param([object[]]$Renames)

    $logPath = Join-Path $InputPath 'entity-fix.tsv'
    $scriptRootFull = [System.IO.Path]::GetFullPath($PSScriptRoot)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("type`told_path`tnew_path") | Out-Null

    foreach ($rename in $Renames) {
        $oldRelative = Get-RelativePathFromBase -BasePath $scriptRootFull -FullPath ([string]$rename.OldPath)
        $newRelative = Get-RelativePathFromBase -BasePath $scriptRootFull -FullPath ([string]$rename.NewPath)
        $lines.Add(("{0}`t{1}`t{2}" -f (ConvertTo-TsvValue ([string]$rename.Kind)), (ConvertTo-TsvValue $oldRelative), (ConvertTo-TsvValue $newRelative))) | Out-Null
    }

    [System.IO.File]::WriteAllLines($logPath, $lines, [System.Text.UTF8Encoding]::new($false))
    return $logPath
}

function Add-RenameCandidate {
    param(
        [System.Collections.Generic.List[object]]$Candidates,
        [string]$Kind,
        [string]$OldPath,
        [string]$ParentPath,
        [string]$OldName,
        [string]$NewName
    )

    if ($NewName -eq $OldName) {
        return
    }

    $newPath = Join-Path $ParentPath $NewName
    $Candidates.Add([pscustomobject]@{
        Kind = $Kind
        OldPath = $OldPath
        NewPath = $newPath
        OldName = $OldName
        NewName = $NewName
    }) | Out-Null
}

function Resolve-RenameCandidates {
    param(
        [object[]]$Candidates,
        [string]$PathType
    )

    $result = [pscustomobject]@{
        Renames = [System.Collections.Generic.List[object]]::new()
        Skipped = 0
    }

    $targetGroups = @($Candidates | Group-Object { ([System.IO.Path]::GetFullPath([string]$_.NewPath)).ToLowerInvariant() })
    $blockedTargets = @{}
    foreach ($group in $targetGroups) {
        if ($group.Count -gt 1) {
            $blockedTargets[$group.Name] = "target dipakai oleh $($group.Count) item"
        }
    }

    foreach ($candidate in $Candidates) {
        $oldFull = [System.IO.Path]::GetFullPath([string]$candidate.OldPath)
        $newFull = [System.IO.Path]::GetFullPath([string]$candidate.NewPath)
        $newKey = $newFull.ToLowerInvariant()

        if ($blockedTargets.ContainsKey($newKey)) {
            $result.Skipped++
            Write-Warning "Skip collision: $($candidate.OldPath) -> $($candidate.NewPath) ($($blockedTargets[$newKey]))"
            continue
        }

        if ((Test-Path -LiteralPath $newFull -PathType $PathType) -and -not $oldFull.Equals($newFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.Skipped++
            Write-Warning "Skip target sudah ada: $($candidate.OldPath) -> $newFull"
            continue
        }

        $result.Renames.Add($candidate) | Out-Null
    }

    return $result
}

$files = @(Get-ChildItem -LiteralPath $InputPath -Recurse -File -Filter '*.mhtml' | Sort-Object FullName)
$directories = @(Get-ChildItem -LiteralPath $InputPath -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending)
$fileCandidates = [System.Collections.Generic.List[object]]::new()
$directoryCandidates = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $newBaseName = ConvertTo-NewEntityName -Name $baseName
    Add-RenameCandidate -Candidates $fileCandidates -Kind 'file' -OldPath $file.FullName -ParentPath $file.DirectoryName -OldName $file.Name -NewName "$newBaseName$($file.Extension)"
}

foreach ($directory in $directories) {
    $newName = ConvertTo-NewEntityName -Name $directory.Name
    Add-RenameCandidate -Candidates $directoryCandidates -Kind 'folder' -OldPath $directory.FullName -ParentPath $directory.Parent.FullName -OldName $directory.Name -NewName $newName
}

$fileResult = Resolve-RenameCandidates -Candidates ([object[]]$fileCandidates.ToArray()) -PathType Leaf
$directoryResult = Resolve-RenameCandidates -Candidates ([object[]]$directoryCandidates.ToArray()) -PathType Container
$renames = [System.Collections.Generic.List[object]]::new()
$renames.AddRange([object[]]$fileResult.Renames.ToArray())
$renames.AddRange([object[]]$directoryResult.Renames.ToArray())
$skipped = $fileResult.Skipped + $directoryResult.Skipped

if ($fileCandidates.Count -eq 0 -and $directoryCandidates.Count -eq 0) {
    Write-Host "Tidak ada nama file/folder yang perlu diperbaiki di $InputPath"
}

if ($renames.Count -eq 0 -and ($fileCandidates.Count + $directoryCandidates.Count) -gt 0) {
    Write-Host "Tidak ada item yang aman untuk direname. Skip: $skipped"
}

Write-Host "File .mhtml ditemukan       : $($files.Count)"
Write-Host "Folder ditemukan           : $($directories.Count)"
Write-Host "File perlu rename           : $($fileCandidates.Count)"
Write-Host "Folder perlu rename         : $($directoryCandidates.Count)"
Write-Host "Aman rename                 : $($renames.Count)"
Write-Host "Skip                        : $skipped"
Write-Host ''

foreach ($rename in $renames) {
    Write-Host "Rename $($rename.Kind) siap: $($rename.OldPath) -> $($rename.NewName)"
    if ($WhatIf) {
        Write-Host "DRY RUN: $($rename.OldPath) -> $($rename.NewName)"
        continue
    }

    Rename-Item -LiteralPath ([string]$rename.OldPath) -NewName ([string]$rename.NewName)
    Write-Host "Rename $($rename.Kind): $($rename.OldName) -> $($rename.NewName)"
}

$updatedTsvCount = Update-TsvFiles
$logPath = ''
if (-not $WhatIf -and $renames.Count -gt 0) {
    $logPath = Write-RenameLog -Renames ([object[]]$renames.ToArray())
    Write-Host "Output list: $logPath"
}

Write-Host ''
if ($WhatIf) {
    Write-Host "Dry run selesai. Item akan direname: $($renames.Count). TSV akan diupdate: $updatedTsvCount. Output list tidak ditulis saat WhatIf."
}
else {
    Write-Host "Selesai. Item direname: $($renames.Count). TSV diupdate: $updatedTsvCount."
}
