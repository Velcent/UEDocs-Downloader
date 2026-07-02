param(
    [string]$MhtmlRoot = (Join-Path $PSScriptRoot 'mhtml'),
    [string[]]$Keys = @('LearnUE', 'LearnMH', 'LearnFN'),
    [switch]$NoBackup,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$MhtmlRoot = [System.IO.Path]::GetFullPath($MhtmlRoot)

function Get-CanonicalUrlKey {
    param([string]$PageUrl)

    try {
        $uri = [Uri]$PageUrl
        return "$($uri.Scheme.ToLowerInvariant())://$($uri.Host.ToLowerInvariant())$($uri.AbsolutePath.TrimEnd('/'))"
    }
    catch {
        return $PageUrl.TrimEnd('/').ToLowerInvariant()
    }
}

function ConvertTo-CleanUrl {
    param([string]$PageUrl)

    if ([string]::IsNullOrWhiteSpace($PageUrl)) {
        return ''
    }

    if ($PageUrl -match '(?i)^/(?!/)') {
        return (($PageUrl -replace '[?#].*$', '').Trim())
    }

    try {
        $uri = [Uri]$PageUrl
        if (-not $uri.IsAbsoluteUri) {
            return (($PageUrl -replace '[?#].*$', '').Trim())
        }
        $builder = [System.UriBuilder]::new($uri)
        $builder.Query = ''
        $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    }
    catch {
        return (($PageUrl -replace '[?#].*$', '').Trim())
    }
}

function ConvertTo-SafeText {
    param([string]$Value)

    return (([string]$Value) -replace '\s+', ' ').Trim()
}

function ConvertTo-XmlAttributeValue {
    param([string]$Value)

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Get-LearningParentMatchKeys {
    param([string]$Url)

    $keys = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return @()
    }

    $clean = ConvertTo-CleanUrl $Url
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return @()
    }

    $key = Get-CanonicalUrlKey -PageUrl $clean
    if (-not $keys.Contains($key)) {
        $keys.Add($key)
    }

    try {
        $uri = [Uri]$clean
        $segments = @($uri.AbsolutePath.Trim('/').Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($segments.Count -gt 5 -and $segments[0] -ieq 'community' -and $segments[1] -ieq 'learning' -and $segments[2] -ieq 'courses') {
            $basePath = '/' + (($segments | Select-Object -First 5) -join '/')
            $baseUrl = "$($uri.Scheme.ToLowerInvariant())://$($uri.Host.ToLowerInvariant())$basePath"
            $baseKey = Get-CanonicalUrlKey -PageUrl $baseUrl
            if (-not $keys.Contains($baseKey)) {
                $keys.Add($baseKey)
            }
        }
    }
    catch {
    }

    return @($keys)
}

function ConvertTo-RelativeRootPath {
    param([string]$Path)

    $root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }

    return $full
}

function Get-DirectContentAnchor {
    param($Li)

    return $Li.SelectSingleNode("./div[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-el ')]/a")
}

function Get-DirectChildItems {
    param($Li)

    return @($Li.SelectNodes("./ul[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-list ')]/li"))
}

function Copy-StringHashSet {
    param([System.Collections.Generic.HashSet[string]]$Source)

    $copy = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Source) {
        foreach ($item in $Source) {
            [void]$copy.Add([string]$item)
        }
    }

    return ,$copy
}

function ConvertFrom-LearningXmlLi {
    param($Li)

    $anchor = Get-DirectContentAnchor -Li $Li
    if (-not $anchor) {
        return $null
    }

    $children = New-Object System.Collections.ArrayList
    foreach ($childLi in Get-DirectChildItems -Li $Li) {
        $childItem = ConvertFrom-LearningXmlLi -Li $childLi
        if ($childItem) {
            [void]$children.Add($childItem)
        }
    }

    return [pscustomobject]@{
        Title = ConvertTo-SafeText ([string]$anchor.InnerText)
        Url = ConvertTo-CleanUrl ([string]$anchor.GetAttribute('href'))
        Children = @($children)
    }
}

function Get-LearningXmlWritableChildren {
    param(
        [object[]]$Items,
        [System.Collections.Generic.HashSet[string]]$WrittenKeys,
        [ref]$RemovedChildren
    )

    $children = New-Object System.Collections.ArrayList
    foreach ($item in @($Items)) {
        if (-not $item) {
            continue
        }

        $href = ConvertTo-CleanUrl ([string]$item.Url)
        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        $key = Get-CanonicalUrlKey -PageUrl $href
        if ($WrittenKeys.Contains($key)) {
            $RemovedChildren.Value++
            continue
        }
        [void]$WrittenKeys.Add($key)
        [void]$children.Add($item)
    }

    return @($children)
}

function Add-LearningXmlChildItems {
    param(
        [System.Collections.ArrayList]$Lines,
        [object[]]$Items,
        [int]$Depth,
        [System.Collections.Generic.HashSet[string]]$WrittenKeys,
        [ref]$RemovedChildren
    )

    $indent = "`t" * $Depth
    foreach ($item in @($Items)) {
        if (-not $item) {
            continue
        }

        $href = ConvertTo-CleanUrl ([string]$item.Url)
        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        $key = Get-CanonicalUrlKey -PageUrl $href
        if ($WrittenKeys.Contains($key)) {
            $RemovedChildren.Value++
            continue
        }

        $children = @(Get-LearningXmlWritableChildren -Items @($item.Children) -WrittenKeys $WrittenKeys -RemovedChildren $RemovedChildren)

        $title = ConvertTo-SafeText ([string]$item.Title)
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = $href
        }

        $safeHref = ConvertTo-XmlAttributeValue $href
        $label = ConvertTo-XmlAttributeValue $title
        $linkClass = if ($children.Count -gt 0) { 'contents-table-link is-parent' } else { 'contents-table-link' }

        [void]$Lines.Add("$indent<li class=""contents-table-item"">")
        [void]$Lines.Add("$indent`t<div class=""contents-table-el""><a class=""$linkClass"" href=""$safeHref"">$label</a></div>")
        if ($children.Count -gt 0) {
            [void]$Lines.Add("$indent`t<ul class=""contents-table-list"">")
            Add-LearningXmlChildItems -Lines $Lines -Items $children -Depth ($Depth + 2) -WrittenKeys $WrittenKeys -RemovedChildren $RemovedChildren
            [void]$Lines.Add("$indent`t</ul>")
        }
        [void]$Lines.Add("$indent</li>")
    }
}

function Get-LearningUrlFromListHtml {
    param([string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ''
    }

    $matches = [regex]::Matches($Html, '<a\b[^>]*\bhref="([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($match in $matches) {
        $href = [System.Net.WebUtility]::HtmlDecode([string]$match.Groups[1].Value)
        if ($href -match '(?i)(?:^https://dev\.epicgames\.com)?/community/learning/') {
            try {
                return ([Uri]::new([Uri]'https://dev.epicgames.com', $href)).AbsoluteUri
            }
            catch {
                return $href
            }
        }
    }

    return ''
}

function ConvertTo-CleanLearningListHtml {
    param(
        [string]$Html,
        [string]$ParentUrl = ''
    )

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ''
    }

    return [regex]::Replace($Html, '(?i)\bhref="([^"]+)"', {
        param($Match)

        $href = [System.Net.WebUtility]::HtmlDecode([string]$Match.Groups[1].Value)
        $isLearningHref = $href -match '(?i)(?:^https://dev\.epicgames\.com)?/community/learning/'
        if ($isLearningHref -and -not [string]::IsNullOrWhiteSpace($ParentUrl)) {
            $cleanHref = ConvertTo-CleanUrl $ParentUrl
        }
        else {
            $cleanHref = ConvertTo-CleanUrl $href
        }

        return 'href="{0}"' -f (ConvertTo-XmlAttributeValue $cleanHref)
    })
}

function Write-LearningXml {
    param(
        [xml]$Xml,
        [string]$Path
    )

    $rootAnchor = $Xml.SelectSingleNode("/root/div[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-el ')]/a")
    if (-not $rootAnchor) {
        throw "Root anchor tidak ditemukan: $Path"
    }

    $parentLis = @($Xml.SelectNodes("/root/ul[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-list ')]/li"))
    $parentKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($li in $parentLis) {
        $anchor = Get-DirectContentAnchor -Li $li
        if ($anchor) {
            $href = ConvertTo-CleanUrl ([string]$anchor.GetAttribute('href'))
            if (-not [string]::IsNullOrWhiteSpace($href)) {
                foreach ($parentKey in @(Get-LearningParentMatchKeys -Url $href)) {
                    [void]$parentKeys.Add($parentKey)
                }
            }
        }
    }

    $removedChildren = 0
    $removedParents = 0
    $lines = New-Object System.Collections.ArrayList
    $rootHref = ConvertTo-XmlAttributeValue (ConvertTo-CleanUrl ([string]$rootAnchor.GetAttribute('href')))
    $rootTitle = ConvertTo-XmlAttributeValue (ConvertTo-SafeText ([string]$rootAnchor.InnerText))
    [void]$lines.Add(('<div class="contents-table-el is-active is-root-entry"><a class="contents-table-link is-parent" href="{0}">{1}</a></div>' -f $rootHref, $rootTitle))
    [void]$lines.Add('<ul class="contents-table-list">')

    $writtenParentKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $writtenAllKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($li in $parentLis) {
        $anchor = Get-DirectContentAnchor -Li $li
        if (-not $anchor) {
            continue
        }

        $href = ConvertTo-CleanUrl ([string]$anchor.GetAttribute('href'))
        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        $parentKey = Get-CanonicalUrlKey -PageUrl $href
        if ($writtenParentKeys.Contains($parentKey)) {
            $removedParents++
            continue
        }
        [void]$writtenParentKeys.Add($parentKey)
        [void]$writtenAllKeys.Add($parentKey)

        $children = New-Object System.Collections.ArrayList
        foreach ($childLi in Get-DirectChildItems -Li $li) {
            $childItem = ConvertFrom-LearningXmlLi -Li $childLi
            if ($childItem) {
                [void]$children.Add($childItem)
            }
        }

        $title = ConvertTo-SafeText ([string]$anchor.InnerText)
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = $href
        }

        $safeHref = ConvertTo-XmlAttributeValue $href
        $label = ConvertTo-XmlAttributeValue $title
        $publishedAt = ConvertTo-XmlAttributeValue ([string]$anchor.ParentNode.GetAttribute('data-published-at'))
        $publishedTimestamp = ConvertTo-XmlAttributeValue ([string]$anchor.ParentNode.GetAttribute('data-published-timestamp'))

        if ($children.Count -gt 0) {
            $children = @(Get-LearningXmlWritableChildren -Items @($children) -WrittenKeys $writtenAllKeys -RemovedChildren ([ref]$removedChildren))
        }

        $linkClass = if ($children.Count -gt 0) { 'contents-table-link is-parent' } else { 'contents-table-link' }

        [void]$lines.Add("`t<li class=""contents-table-item"">")
        [void]$lines.Add("`t`t<div class=""contents-table-el"" data-published-at=""$publishedAt"" data-published-timestamp=""$publishedTimestamp""><a class=""$linkClass"" href=""$safeHref"">$label</a></div>")

        if ($children.Count -gt 0) {
            [void]$lines.Add("`t`t<ul class=""contents-table-list"">")
            Add-LearningXmlChildItems -Lines $lines -Items @($children) -Depth 3 -WrittenKeys $writtenAllKeys -RemovedChildren ([ref]$removedChildren)
            [void]$lines.Add("`t`t</ul>")
        }

        [void]$lines.Add("`t</li>")
    }

    [void]$lines.Add('</ul>')
    Set-Content -LiteralPath $Path -Value ([string[]]$lines.ToArray()) -Encoding UTF8
    return [pscustomobject]@{
        RemovedParents = $removedParents
        RemovedChildren = $removedChildren
    }
}

function Get-LearningXmlParentKeys {
    param([string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw
    [xml]$xml = "<root>$content</root>"
    $keys = New-Object System.Collections.ArrayList
    foreach ($anchor in @($xml.SelectNodes("/root/ul[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-list ')]/li/div[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-el ')]/a"))) {
        $href = ConvertTo-CleanUrl ([string]$anchor.GetAttribute('href'))
        if (-not [string]::IsNullOrWhiteSpace($href)) {
            [void]$keys.Add((Get-CanonicalUrlKey -PageUrl $href))
        }
    }

    return @($keys)
}

function Get-LearningXmlParentEntries {
    param([string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw
    [xml]$xml = "<root>$content</root>"
    $entries = New-Object System.Collections.ArrayList
    foreach ($anchor in @($xml.SelectNodes("/root/ul[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-list ')]/li/div[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-el ')]/a"))) {
        $href = ConvertTo-CleanUrl ([string]$anchor.GetAttribute('href'))
        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        [void]$entries.Add([pscustomobject]@{
            Key = Get-CanonicalUrlKey -PageUrl $href
            Keys = @(Get-LearningParentMatchKeys -Url $href)
            Url = $href
            Title = ConvertTo-SafeText ([string]$anchor.InnerText)
        })
    }

    return @($entries)
}

function Get-LearningListEntries {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $entries = New-Object System.Collections.ArrayList
    $pendingComment = ''
    foreach ($line in Get-Content -LiteralPath $Path) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text -match '^\s*<!--') {
            $pendingComment = $text
            continue
        }

        $url = Get-LearningUrlFromListHtml -Html $text
        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }

        [void]$entries.Add([pscustomobject]@{
            Key = Get-CanonicalUrlKey -PageUrl $url
            Comment = $pendingComment
            Html = $text
        })
        $pendingComment = ''
    }

    return @($entries)
}

function Sync-LearningListXml {
    param(
        [string]$XmlPath,
        [string]$ListPath,
        [string]$ReportPath
    )

    if (-not (Test-Path -LiteralPath $ListPath)) {
        return [pscustomobject]@{
            Updated = $false
            Kept = 0
            Removed = 0
        }
    }

    $parentEntries = @(Get-LearningXmlParentEntries -Path $XmlPath)
    $parentKeySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($parent in $parentEntries) {
        foreach ($key in @($parent.Keys)) {
            [void]$parentKeySet.Add([string]$key)
        }
    }
    $entries = @(Get-LearningListEntries -Path $ListPath)
    $sourceLength = (Get-Item -LiteralPath $ListPath).Length
    if ($parentEntries.Count -eq 0) {
        Write-Warning "Skip patch list karena parent XML tidak terbaca: $(ConvertTo-RelativeRootPath $XmlPath)"
        return [pscustomobject]@{
            Updated = $false
            Kept = 0
            Removed = 0
        }
    }
    if ($entries.Count -eq 0 -and $sourceLength -gt 0) {
        Write-Warning "Skip patch list karena entry list tidak terbaca: $(ConvertTo-RelativeRootPath $ListPath)"
        return [pscustomobject]@{
            Updated = $false
            Kept = 0
            Removed = 0
        }
    }

    $entriesByKey = @{}
    $duplicateListKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if (-not $entriesByKey.ContainsKey($entry.Key)) {
            $entriesByKey[$entry.Key] = $entry
        }
        else {
            [void]$duplicateListKeys.Add([string]$entry.Key)
        }
    }

    $matchedListKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $reportLines = New-Object System.Collections.ArrayList
    [void]$reportLines.Add("Status`tKey`tUrl`tTitle")
    $missingCount = 0
    foreach ($parent in $parentEntries) {
        $matchedEntry = $null
        foreach ($key in @($parent.Keys)) {
            if ($entriesByKey.ContainsKey($key)) {
                $matchedEntry = $entriesByKey[$key]
                break
            }
        }

        if (-not $matchedEntry) {
            $title = ([string]$parent.Title) -replace "`t", ' ' -replace "`r?`n", ' '
            [void]$reportLines.Add(("MissingInList`t{0}`t{1}`t{2}" -f $parent.Key, $parent.Url, $title))
            $missingCount++
        }
        else {
            [void]$matchedListKeys.Add([string]$matchedEntry.Key)
        }
    }

    $lines = New-Object System.Collections.ArrayList
    $kept = 0
    foreach ($parent in $parentEntries) {
        $entry = $null
        foreach ($key in @($parent.Keys)) {
            if ($entriesByKey.ContainsKey($key)) {
                $entry = $entriesByKey[$key]
                break
            }
        }

        if (-not $entry) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Comment)) {
            [void]$lines.Add([string]$entry.Comment)
        }
        [void]$lines.Add((ConvertTo-CleanLearningListHtml -Html ([string]$entry.Html) -ParentUrl ([string]$parent.Url)))
        $kept++
    }

    $extraCount = 0
    $duplicateCount = 0
    foreach ($entry in $entries) {
        $entryUrl = ConvertTo-CleanUrl ([string](Get-LearningUrlFromListHtml -Html ([string]$entry.Html)))
        if (-not $matchedListKeys.Contains([string]$entry.Key) -and -not $parentKeySet.Contains([string]$entry.Key)) {
            [void]$reportLines.Add(("ExtraInList`t{0}`t{1}`t" -f $entry.Key, $entryUrl))
            $extraCount++
        }
        elseif ($duplicateListKeys.Contains([string]$entry.Key) -and -not [object]::ReferenceEquals($entry, $entriesByKey[$entry.Key])) {
            [void]$reportLines.Add(("DuplicateInList`t{0}`t{1}`t" -f $entry.Key, $entryUrl))
            $duplicateCount++
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        Set-Content -LiteralPath $ReportPath -Value ([string[]]$reportLines.ToArray()) -Encoding UTF8
    }

    Set-Content -LiteralPath $ListPath -Value ([string[]]$lines.ToArray()) -Encoding UTF8
    return [pscustomobject]@{
        Updated = $true
        Kept = $kept
        Removed = [Math]::Max(0, $entries.Count - $kept)
        Missing = $missingCount
        Extra = $extraCount
        Duplicate = $duplicateCount
    }
}

foreach ($key in $Keys) {
    $path = Join-Path $MhtmlRoot "$key.xml"
    $listPath = Join-Path $MhtmlRoot "$key-list.xml"
    $reportPath = Join-Path $MhtmlRoot "$key-patch.tsv"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "File tidak ditemukan: $(ConvertTo-RelativeRootPath $path)"
        continue
    }

    $content = Get-Content -LiteralPath $path -Raw
    [xml]$xml = "<root>$content</root>"

    if (-not $NoBackup) {
        $backupPath = "$path.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force
        Write-Host "Backup: $(ConvertTo-RelativeRootPath $backupPath)"
        if (Test-Path -LiteralPath $listPath) {
            $listBackupPath = "$listPath.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
            Copy-Item -LiteralPath $listPath -Destination $listBackupPath -Force
            Write-Host "Backup: $(ConvertTo-RelativeRootPath $listBackupPath)"
        }
    }

    $patchResult = Write-LearningXml -Xml $xml -Path $path
    Write-Host "Patch XML: $(ConvertTo-RelativeRootPath $path) ($($patchResult.RemovedParents) link duplikat dihapus, $($patchResult.RemovedChildren) child duplikat dihapus)"

    $listResult = Sync-LearningListXml -XmlPath $path -ListPath $listPath -ReportPath $reportPath
    if ($listResult.Updated) {
        Write-Host "Patch list: $(ConvertTo-RelativeRootPath $listPath) ($($listResult.Kept) cocok XML, $($listResult.Removed) dibuang, $($listResult.Missing) kurang, $($listResult.Extra) kelebihan, $($listResult.Duplicate) duplikat)"
        Write-Host "Report: $(ConvertTo-RelativeRootPath $reportPath)"
    }
    else {
        Write-Warning "List tidak ditemukan: $(ConvertTo-RelativeRootPath $listPath)"
    }
}

Write-Host ""
Write-Host "Selesai patch XML learning."
if (-not $NoPause) {
    pause
}
