@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "$BaseDir = (Resolve-Path -LiteralPath '%~dp0').Path.TrimEnd('\') + '\';" ^
  "$ListPath = Join-Path $BaseDir 'mhtml\bp_api-list.tsv';" ^
  "$FolderPath = Join-Path $BaseDir 'mhtml\BlueprintAPI';" ^
  "if (-not (Test-Path -LiteralPath $ListPath -PathType Leaf)) { throw ('File TSV tidak ditemukan: ' + $ListPath) }" ^
  "if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) { throw ('Folder tidak ditemukan: ' + $FolderPath) }" ^
  "function Get-Key([string]$PathValue) {" ^
  "  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }" ^
  "  $p = $PathValue.Trim().Trim([char]34) -replace '/', '\';" ^
  "  while ($p.StartsWith('.\')) { $p = $p.Substring(2) }" ^
  "  if ([IO.Path]::IsPathRooted($p)) {" ^
  "    $full = [IO.Path]::GetFullPath($p);" ^
  "    if ($full.StartsWith($BaseDir, [StringComparison]::OrdinalIgnoreCase)) { $p = $full.Substring($BaseDir.Length) }" ^
  "  }" ^
  "  return $p.TrimStart('\').ToLowerInvariant()" ^
  "}" ^
  "function Add-Path([hashtable]$Map, [hashtable]$Dup, [string]$PathValue) {" ^
  "  $key = Get-Key $PathValue;" ^
  "  if ($null -eq $key) { return }" ^
  "  $display = ($PathValue.Trim().Trim([char]34) -replace '/', '\').TrimStart('\');" ^
  "  if ($Map.ContainsKey($key)) { $Dup[$key] = $Map[$key] } else { $Map[$key] = $display }" ^
  "}" ^
  "$expected = @{}; $dupes = @{};" ^
  "Import-Csv -LiteralPath $ListPath -Delimiter \"`t\" | ForEach-Object { Add-Path $expected $dupes $_.file };" ^
  "$actual = @{};" ^
  "Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Filter '*.mhtml' | ForEach-Object { $rel = $_.FullName.Substring($BaseDir.Length); $actual[(Get-Key $rel)] = $rel };" ^
  "$missing = @($expected.Keys | Where-Object { -not $actual.ContainsKey($_) } | Sort-Object);" ^
  "$extra = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) } | Sort-Object);" ^
  "Write-Host 'BP API Sync Check';" ^
  "Write-Host ('TSV         : ' + $ListPath);" ^
  "Write-Host ('Folder      : ' + $FolderPath);" ^
  "Write-Host ('Daftar TSV  : ' + $expected.Count);" ^
  "Write-Host ('File asli   : ' + $actual.Count);" ^
  "Write-Host ('Cocok       : ' + ($expected.Count - $missing.Count));" ^
  "Write-Host '';" ^
  "Write-Host ('Kekurangan di folder (ada di TSV, tidak ada di file asli): ' + $missing.Count);" ^
  "if ($missing.Count -eq 0) { Write-Host '  - tidak ada' } else { $missing | ForEach-Object { Write-Host ('  - ' + $expected[$_]) } }" ^
  "Write-Host '';" ^
  "Write-Host ('Kelebihan di folder (ada di file asli, tidak ada di TSV): ' + $extra.Count);" ^
  "if ($extra.Count -eq 0) { Write-Host '  - tidak ada' } else { $extra | ForEach-Object { Write-Host ('  + ' + $actual[$_]) } }" ^
  "Write-Host '';" ^
  "Write-Host ('Duplikat path di TSV: ' + $dupes.Count);" ^
  "if ($dupes.Count -eq 0) { Write-Host '  - tidak ada' } else { $dupes.Keys | Sort-Object | ForEach-Object { Write-Host ('  ! ' + $dupes[$_]) } }" ^
  "Write-Host '';" ^
  "if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $dupes.Count -eq 0) { Write-Host 'Kesimpulan: SAMA'; exit 0 } else { Write-Host 'Kesimpulan: BERBEDA'; exit 1 }"

set "BP_API_SYNC_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %BP_API_SYNC_EXIT%
