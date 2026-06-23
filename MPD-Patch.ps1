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

function Get-VideoIdFromEmbedUrl {
    param([string]$Url)

    $match = [regex]::Match($Url, '/videos/(?<id>[^/]+)/embed\.html', 'IgnoreCase')
    if ($match.Success) {
        return $match.Groups['id'].Value
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

function Get-VideoPlayerHtml {
    param(
        [string]$VideoId,
        [string]$PosterUrl
    )

    $mp4Link = "https://media.local/video/mp4/$VideoId.mp4"
    $background = '#000'

    if (-not [string]::IsNullOrWhiteSpace($PosterUrl)) {
        $background = "#000 url(""$(ConvertTo-CssUrlValue $PosterUrl)"") center / contain no-repeat"
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

.video-link {
  display: block;
  width: 100%;
  height: 100%;
  background: $background;
  position: relative;
}

.play {
  position: absolute;
  inset: 0;
  margin: auto;
  width: 72px;
  height: 72px;
  border-radius: 50%;
  background: rgba(0,0,0,.55);
}

.play::after {
  content: "";
  position: absolute;
  left: 29px;
  top: 22px;
  border-left: 24px solid white;
  border-top: 14px solid transparent;
  border-bottom: 14px solid transparent;
}
</style>
</head>
<body>
<a class="video-link" href="$mp4Link">
  <span class="play"></span>
</a>
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

function Patch-EmbedPart {
    param(
        [string]$MhtmlText,
        [string]$EmbedUrl,
        [string]$VideoId
    )

    $contentLocation = "Content-Location: $EmbedUrl"
    $contentLocationIndex = $MhtmlText.IndexOf($contentLocation, [System.StringComparison]::OrdinalIgnoreCase)
    if ($contentLocationIndex -lt 0) {
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
    $_.mhtml_file -and $_.embed_html
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
        $videoId = Get-VideoIdFromEmbedUrl $row.embed_html
        if (-not $videoId) {
            Write-Warning "Cannot parse video id from embed URL: $($row.embed_html)"
            continue
        }

        $result = Patch-EmbedPart -MhtmlText $text -EmbedUrl $row.embed_html -VideoId $videoId
        $text = $result.Text

        if ($result.Patched) {
            $patchedInFile++
            $totalPatched++
            Write-Host "Patched embed: $videoId -> video/mp4/$videoId.mp4"
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
