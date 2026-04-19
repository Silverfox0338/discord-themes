param(
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$root       = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$authorsRaw = Get-Content (Join-Path $root "theme-authors.json") -Raw | ConvertFrom-Json
$baseRaw    = "https://raw.githubusercontent.com/Silverfox0338/discord-themes/main/"
$baseBlob   = "https://github.com/Silverfox0338/discord-themes/blob/main/"

if (-not $OutputPath) {
  $OutputPath = Join-Path $root "docs" "themes.json"
}

# Build authors map
$authors = [ordered]@{}
foreach ($folderName in $authorsRaw.folders.PSObject.Properties.Name) {
  $info = $authorsRaw.folders.$folderName

  $profileMd = Join-Path $root $folderName "AUTHOR.md"
  $profileUrl = $null
  if (Test-Path $profileMd) {
    $encoded = ($folderName -split ' ' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '%20'
    $profileUrl = $baseBlob + $encoded + "/AUTHOR.md"
  }

  $authors[$info.author] = [ordered]@{
    github    = $info.github
    githubId  = $info.githubId
    folder    = $folderName
    profile   = $profileUrl
    trusted   = [bool]$info.trusted
  }
}

# Walk CSS files and extract metadata
$themes = [System.Collections.Generic.List[object]]::new()

foreach ($folderName in $authorsRaw.folders.PSObject.Properties.Name) {
  $info       = $authorsRaw.folders.$folderName
  $folderPath = Join-Path $root $folderName

  if (-not (Test-Path $folderPath)) { continue }

  $cssFiles = Get-ChildItem -Path $folderPath -Filter "*.css" -Recurse -File

  foreach ($css in $cssFiles) {
    $content = Get-Content $css.FullName -Raw -Encoding UTF8

    $name    = if ($content -match '(?m)@name\s+(.+)$')        { $Matches[1].Trim() } else { $css.BaseName }
    $version = if ($content -match '(?m)@version\s+(.+)$')     { $Matches[1].Trim() } else { '1.0.0' }
    $desc    = if ($content -match '(?m)@description\s+(.+)$') { $Matches[1].Trim() } else { '' }

    # Build raw URL — encode each path segment
    $relativePath = $css.FullName.Substring($root.Length).TrimStart('\', '/')
    $segments     = $relativePath -split '[/\\]'
    $encodedPath  = ($segments | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $rawUrl       = $baseRaw + $encodedPath

    $themes.Add([ordered]@{
      name        = $name
      author      = $info.author
      version     = $version
      description = $desc
      raw         = $rawUrl
    })
  }
}

# Sort: author asc, name asc
$sorted = $themes | Sort-Object { $_.author }, { $_.name }

$output = [ordered]@{
  generated = (Get-Date -Format "o")
  authors   = $authors
  themes    = @($sorted)
}

$json = $output | ConvertTo-Json -Depth 6 -Compress:$false
[System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host "Wrote $($sorted.Count) themes → $OutputPath"
