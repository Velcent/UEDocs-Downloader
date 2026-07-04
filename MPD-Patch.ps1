param(
    [string]$Root = $PSScriptRoot,
    [string]$ListFile = 'video\mpd-list.tsv'
)

$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $Root).Path
$ListPath = Join-Path $Root $ListFile

if (-not (Test-Path -LiteralPath $ListPath)) {
    throw "List file not found: $ListPath"
}

function Convert-FileUriToPath {
    param([string]$Value)

    if ($Value -match '^file:/') {
        return ([Uri]$Value).LocalPath
    }

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }

    return Join-Path $Root $Value
}

function Test-InMhtmlFolder {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath((Convert-FileUriToPath $Path))
        $mhtmlRoot = [System.IO.Path]::GetFullPath((Join-Path $Root 'mhtml')).TrimEnd('\') + '\'
        return $fullPath.StartsWith($mhtmlRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-VideoIdFromEmbedUrl {
    param([string]$Url)

    $match = [regex]::Match($Url, '/videos/(?<id>[^/]+)/embed\.html', 'IgnoreCase')
    if ($match.Success) {
        return $match.Groups['id'].Value
    }

    return $null
}

function Get-YoutubeVideoIdFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Url).Replace('\/', '/')
    $patterns = @(
        '(?i)(?:(?:www\.)?youtube(?:-nocookie)?\.com/(?:embed|shorts|live)/|youtu\.be/)(?<id>[A-Za-z0-9_-]{11})',
        '(?i)(?:www\.)?youtube(?:-nocookie)?\.com/.*?[?&]v=(?<id>[A-Za-z0-9_-]{11})'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($decoded, $pattern)
        if ($match.Success) {
            return $match.Groups['id'].Value
        }
    }

    return $null
}

function Get-VideoPatchInfo {
    param([string]$Url)

    $epicId = Get-VideoIdFromEmbedUrl $Url
    if ($epicId) {
        return [pscustomobject]@{
            Kind = 'epic'
            Id = $epicId
        }
    }

    $youtubeId = Get-YoutubeVideoIdFromUrl $Url
    if ($youtubeId) {
        return [pscustomobject]@{
            Kind = 'youtube'
            Id = $youtubeId
        }
    }

    return $null
}

function ConvertTo-QuotedPrintableHtml {
    param([string]$Html)

    return $Html -replace '=', '=3D'
}

function ConvertFrom-QuotedPrintableText {
    param([string]$Text)

    $withoutSoftBreaks = [regex]::Replace($Text, "=\r?\n", '')
    return [regex]::Replace($withoutSoftBreaks, '=([0-9A-Fa-f]{2})', {
        param($Match)
        [char][Convert]::ToInt32($Match.Groups[1].Value, 16)
    })
}

function ConvertTo-HtmlAttributeValue {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }

    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-Mp4SourceForVideoId {
    param([string]$VideoId)

    return "$(ConvertTo-HtmlAttributeValue "https://media.local/assets/video/$VideoId.mp4")"
}

function Repair-PatchedMediaLocalUrls {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $pattern = "(?i)(?<url>https://media\.local/assets/video/[A-Za-z0-9_-]+\.mp4)[\)\]\}\.,;:]+(?=(`"|&quot;|'|<|>|\s|$))"
    return [regex]::Replace($Text, $pattern, {
        param($Match)
        return $Match.Groups['url'].Value
    })
}

function ConvertTo-CssUrlValue {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }

    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Get-PosterUrlFromEmbedBody {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    $decodedBody = [System.Net.WebUtility]::HtmlDecode((ConvertFrom-QuotedPrintableText $Body))
    $patterns = @(
        'background-image:\s*url\((?:&quot;|"|''|\\")?(?<url>https://dev\.epicgames\.com/community/api/cms/image/[^"''\)\s\\]+)',
        'background-image:\s*url\((?:&quot;|"|''|\\")?(?<url>https://[^"''\)\s\\]+)'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($decodedBody, $pattern, 'IgnoreCase')
        if ($match.Success) {
            return $match.Groups['url'].Value
        }
    }

    return $null
}

function Get-PosterUrlFromLocalEmbedFile {
    param([string]$VideoId)

    if ([string]::IsNullOrWhiteSpace($VideoId)) {
        return $null
    }

    $embedPath = Join-Path $Root "video\embed\$VideoId.html"
    if (-not (Test-Path -LiteralPath $embedPath)) {
        return $null
    }

    $embedText = [System.IO.File]::ReadAllText($embedPath)
    $decodedEmbedText = [System.Net.WebUtility]::HtmlDecode($embedText).
        Replace('\/', '/').
        Replace('\u0026', '&')
    $escapedVideoId = [regex]::Escape($VideoId)
    $patterns = @(
        'const\s+posterUrl\s*=\s*`\$\{document\.location\.origin\}(?<path>/community/api/cms/image/[^`"]+)',
        'const\s+posterUrl\s*=\s*["''](?<path>/community/api/cms/image/[^"'']+)["'']',
        'background-image:\s*url\((?:&quot;|"|''|\\")?(?<url>https://dev\.epicgames\.com/community/api/cms/image/[^"''\)\s\\]+)',
        'background-image:\s*url\((?:&quot;|"|''|\\")?(?<path>/community/api/cms/image/[^"''\)\s\\]+)',
        ('(?<url>https?://(?:i\.ytimg\.com|img\.youtube\.com)/(?:vi|vi_webp)/{0}/[^"''<>\s\\)]+)' -f $escapedVideoId),
        ('(?<url>https?://[^"''<>\s\\)]+ytimg\.com/[^"''<>\s\\)]*/{0}/[^"''<>\s\\)]+)' -f $escapedVideoId)
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($decodedEmbedText, $pattern, 'IgnoreCase')
        if (-not $match.Success) {
            continue
        }

        if ($match.Groups['url'].Success) {
            return $match.Groups['url'].Value.TrimEnd(',', '.', ';')
        }

        if ($match.Groups['path'].Success) {
            return "https://dev.epicgames.com$($match.Groups['path'].Value)"
        }
    }

    return $null
}

function Get-VideoPlayerHtml {
    param(
        [string]$VideoId,
        [string]$PosterUrl
    )

    $mp4Source = Get-Mp4SourceForVideoId $VideoId
    $posterAttribute = ''

    if (-not [string]::IsNullOrWhiteSpace($PosterUrl)) {
        $posterAttribute = " poster=""$(ConvertTo-HtmlAttributeValue $PosterUrl)"""
    }

    return @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
html, body {
  width: 100%;
  height: 100%;
  margin: 0;
  background: #000;
}

.video-player {
  width: 100%;
  height: 100%;
  display: block;
  object-fit: contain;
  background: #000;
}
</style>
</head>
<body>
<video class="video-player" src="$mp4Source"$posterAttribute controls preload="metadata"></video>
</body>
</html>
"@
}

function Get-LineEnding {
    param([string]$Text)

    if ($Text.Contains("`r`n")) {
        return "`r`n"
    }

    return "`n"
}

function Find-HeaderBodySeparator {
    param(
        [string]$Text,
        [int]$StartIndex
    )

    $crlf = $Text.IndexOf("`r`n`r`n", $StartIndex, [System.StringComparison]::Ordinal)
    $lf = $Text.IndexOf("`n`n", $StartIndex, [System.StringComparison]::Ordinal)

    if ($crlf -lt 0 -and $lf -lt 0) {
        return $null
    }

    if ($crlf -ge 0 -and ($lf -lt 0 -or $crlf -lt $lf)) {
        return @{
            Index = $crlf
            Length = 4
        }
    }

    return @{
        Index = $lf
        Length = 2
    }
}

function Find-VideoContentLocationIndex {
    param(
        [string]$MhtmlText,
        [string]$EmbedUrl,
        [string]$VideoId,
        [string]$Kind
    )

    if ($Kind -eq 'epic') {
        $contentLocation = "Content-Location: $EmbedUrl"
        return $MhtmlText.IndexOf($contentLocation, [System.StringComparison]::OrdinalIgnoreCase)
    }

    foreach ($match in [regex]::Matches($MhtmlText, 'Content-Location:\s*(?<url>https?://[^\r\n]+youtube[^\r\n]+)', 'IgnoreCase')) {
        $contentLocationUrl = $match.Groups['url'].Value.Trim()
        if ((Get-YoutubeVideoIdFromUrl $contentLocationUrl) -eq $VideoId) {
            return $match.Index
        }
    }

    foreach ($match in [regex]::Matches($MhtmlText, 'Content-Location:\s*(?<url>https?://youtu\.be/[^\r\n]+)', 'IgnoreCase')) {
        $contentLocationUrl = $match.Groups['url'].Value.Trim()
        if ((Get-YoutubeVideoIdFromUrl $contentLocationUrl) -eq $VideoId) {
            return $match.Index
        }
    }

    return -1
}

function Patch-YoutubeLinkFallback {
    param(
        [string]$MhtmlText,
        [string]$VideoId
    )

    $mp4Source = Get-Mp4SourceForVideoId $VideoId
    $escapedVideoId = [regex]::Escape($VideoId)
    $watchPattern = 'https?://(?:www\.)?youtube(?:-nocookie)?\.com/watch\?[^"''<>\s\\)]*v(?:=|=3D)' + $escapedVideoId + '[^"''<>\s\\)]*'
    $embedPattern = 'https?://(?:www\.)?youtube(?:-nocookie)?\.com/(?:embed|shorts|live)/' + $escapedVideoId + '[^"''<>\s\\)]*'
    $shortUrlPattern = 'https?://youtu\.be/' + $escapedVideoId + '[^"''<>\s\\)]*'
    $patterns = @($watchPattern, $embedPattern, $shortUrlPattern)

    $patchedText = $MhtmlText
    $replacementCount = 0

    foreach ($pattern in $patterns) {
        $urlMatches = [regex]::Matches($patchedText, $pattern, 'IgnoreCase')
        if ($urlMatches.Count -le 0) {
            continue
        }

        $replacementCount += $urlMatches.Count
        $patchedText = [regex]::Replace($patchedText, $pattern, $mp4Source, 'IgnoreCase')
    }

    if ($replacementCount -gt 0) {
        $patchedText = Repair-PatchedMediaLocalUrls -Text $patchedText
    }

    return @{
        Text = $patchedText
        Patched = ($replacementCount -gt 0)
        ReplacementCount = $replacementCount
    }
}

function Patch-EmbedPart {
    param(
        [string]$MhtmlText,
        [string]$EmbedUrl,
        [string]$VideoId,
        [string]$Kind
    )

    $contentLocationIndex = Find-VideoContentLocationIndex -MhtmlText $MhtmlText -EmbedUrl $EmbedUrl -VideoId $VideoId -Kind $Kind
    if ($contentLocationIndex -lt 0) {
        if ($Kind -eq 'youtube') {
            $fallback = Patch-YoutubeLinkFallback -MhtmlText $MhtmlText -VideoId $VideoId
            if ($fallback.Patched) {
                Write-Host "Embed URL not found; patched YouTube link instead: $EmbedUrl"
                return $fallback
            }
        }

        Write-Warning "Embed URL not found in MHTML: $EmbedUrl"
        return @{
            Text = $MhtmlText
            Patched = $false
        }
    }

    $boundaryIndex = $MhtmlText.LastIndexOf('------MultipartBoundary', $contentLocationIndex, [System.StringComparison]::Ordinal)
    if ($boundaryIndex -lt 0) {
        Write-Warning "Boundary before embed URL not found: $EmbedUrl"
        return @{
            Text = $MhtmlText
            Patched = $false
        }
    }

    $separator = Find-HeaderBodySeparator -Text $MhtmlText -StartIndex $contentLocationIndex
    if (-not $separator) {
        Write-Warning "Header/body separator not found for: $EmbedUrl"
        return @{
            Text = $MhtmlText
            Patched = $false
        }
    }

    $bodyStart = $separator.Index + $separator.Length
    $nextBoundaryMatch = [regex]::Match($MhtmlText.Substring($bodyStart), '(?m)^------MultipartBoundary')
    if (-not $nextBoundaryMatch.Success) {
        Write-Warning "Next boundary after embed URL not found: $EmbedUrl"
        return @{
            Text = $MhtmlText
            Patched = $false
        }
    }

    $nextBoundaryIndex = $bodyStart + $nextBoundaryMatch.Index
    $headers = $MhtmlText.Substring($boundaryIndex, $bodyStart - $boundaryIndex)
    $oldBody = $MhtmlText.Substring($bodyStart, $nextBoundaryIndex - $bodyStart)
    $posterUrl = Get-PosterUrlFromEmbedBody $oldBody
    if ([string]::IsNullOrWhiteSpace($posterUrl)) {
        $posterUrl = Get-PosterUrlFromLocalEmbedFile $VideoId
    }
    $html = Get-VideoPlayerHtml -VideoId $VideoId -PosterUrl $posterUrl
    $lineEnding = Get-LineEnding $MhtmlText

    if ($headers -match '(?im)^Content-Transfer-Encoding:\s*quoted-printable\s*$') {
        $replacementBody = (ConvertTo-QuotedPrintableHtml $html) -replace "`r?`n", $lineEnding
    }
    else {
        $replacementBody = $html -replace "`r?`n", $lineEnding
    }

    $replacementBody = $replacementBody.TrimEnd("`r", "`n") + $lineEnding
    $patchedText = $MhtmlText.Substring(0, $bodyStart) + $replacementBody + $MhtmlText.Substring($nextBoundaryIndex)

    return @{
        Text = $patchedText
        Patched = $true
    }
}

$rows = Import-Csv -LiteralPath $ListPath -Delimiter "`t" | Where-Object {
    $_.mhtml_file -and $_.embed_html -and (Test-InMhtmlFolder $_.mhtml_file) -and (Get-VideoPatchInfo $_.embed_html)
}

if (-not $rows) {
    Write-Host "No patch entries found in $ListPath"
    exit 0
}

$groups = $rows | Group-Object -Property mhtml_file
$totalPatched = 0

foreach ($group in $groups) {
    $mhtmlPath = Convert-FileUriToPath $group.Name
    if (-not (Test-Path -LiteralPath $mhtmlPath)) {
        Write-Warning "MHTML file not found: $mhtmlPath"
        continue
    }

    Write-Host ""
    Write-Host "Patching MHTML: $mhtmlPath"

    $text = [System.IO.File]::ReadAllText($mhtmlPath)
    $patchedInFile = 0

    foreach ($row in $group.Group) {
        $patchInfo = Get-VideoPatchInfo $row.embed_html
        if (-not $patchInfo) {
            Write-Warning "Cannot parse video id from embed URL: $($row.embed_html)"
            continue
        }

        $videoId = $patchInfo.Id
        $result = Patch-EmbedPart -MhtmlText $text -EmbedUrl $row.embed_html -VideoId $videoId -Kind $patchInfo.Kind
        $text = Repair-PatchedMediaLocalUrls -Text $result.Text

        if ($result.Patched) {
            $patchedInFile++
            $totalPatched++
            Write-Host "Patched embed: $videoId -> $videoId.mp4"
        }
    }

    if ($patchedInFile -gt 0) {
        [System.IO.File]::WriteAllText($mhtmlPath, $text, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Saved patched MHTML: $patchedInFile embed(s)"
    }
    else {
        Write-Host 'No embeds patched in this file.'
    }
}

Write-Host ""
Write-Host "Done. Patched $totalPatched embed(s)."
pause
