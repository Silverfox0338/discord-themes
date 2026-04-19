param(
  [string]$OutputPath = "README.md",
  [string]$MetadataPath = "theme-authors.json",
  [string]$PredictPngRawUrl = "",
  [string]$Folder = "",
  [switch]$NoAuthorPrompt,
  [switch]$Doctor
)

$ErrorActionPreference = "Stop"

function Write-Utf8BomFile {
  param(
    [string]$Path,
    [string]$Content
  )

  if ($null -eq $Content) {
    $Content = ""
  }

  if (-not $Content.EndsWith([Environment]::NewLine)) {
    $Content += [Environment]::NewLine
  }

  $utf8Bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8Bom)
}

function Get-RepoRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function To-RelativePath {
  param(
    [string]$Root,
    [string]$Path
  )

  $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
  $resolvedPath = (Resolve-Path -LiteralPath $Path).Path

  if (-not $resolvedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $resolvedRoot += [System.IO.Path]::DirectorySeparatorChar
  }

  $rootUri = New-Object System.Uri($resolvedRoot)
  $fileUri = New-Object System.Uri($resolvedPath)
  $relativeUri = $rootUri.MakeRelativeUri($fileUri)

  return ([System.Uri]::UnescapeDataString($relativeUri.ToString())).Replace('\', '/')
}

function Get-MetadataValue {
  param(
    [string]$Raw,
    [string]$Key
  )

  $pattern = "(?mi)^\s*\*\s*@${Key}\s+(.*)\s*$"
  $match = [regex]::Match($Raw, $pattern)
  if ($match.Success) {
    return $match.Groups[1].Value.Trim()
  }

  return ""
}

function Escape-TableCell {
  param(
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return "-"
  }

  $singleLine = ($Value -replace "\r?\n", " ").Trim()
  return $singleLine.Replace("|", "\|")
}

function Get-LinkPath {
  param(
    [string]$RelativePath
  )

  $segments = $RelativePath -split "/"
  $encoded = foreach ($segment in $segments) {
    ([System.Uri]::EscapeDataString($segment)).Replace("'", "%27")
  }

  return ($encoded -join "/")
}

function Get-RepoRelativePath {
  param(
    [string]$RepoRoot,
    [string]$InputPath
  )

  if ([string]::IsNullOrWhiteSpace($InputPath)) {
    return ""
  }

  $repoFull = [System.IO.Path]::GetFullPath($RepoRoot)
  if (-not $repoFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $repoFull += [System.IO.Path]::DirectorySeparatorChar
  }

  $trimmedInput = $InputPath.Trim().Trim('"')
  $fullPath = if ([System.IO.Path]::IsPathRooted($trimmedInput)) {
    [System.IO.Path]::GetFullPath($trimmedInput)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $trimmedInput))
  }

  if (-not $fullPath.StartsWith($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Path must be inside the repo root."
  }

  $relativePath = $fullPath.Substring($repoFull.Length)
  return $relativePath.Replace('\', '/')
}

function Get-GitOutput {
  param(
    [string[]]$CommandArgs
  )

  try {
    $output = & git @CommandArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
      return ""
    }

    if ($null -eq $output) {
      return ""
    }

    return ($output -join [Environment]::NewLine).Trim()
  } catch {
    return ""
  }
}

function Get-BranchName {
  $originHead = Get-GitOutput -CommandArgs @("symbolic-ref", "refs/remotes/origin/HEAD")
  if (-not [string]::IsNullOrWhiteSpace($originHead) -and $originHead -match "^refs/remotes/origin/(.+)$") {
    return $matches[1]
  }

  $currentBranch = Get-GitOutput -CommandArgs @("rev-parse", "--abbrev-ref", "HEAD")
  if (-not [string]::IsNullOrWhiteSpace($currentBranch) -and $currentBranch -ne "HEAD") {
    return $currentBranch
  }

  return "main"
}

function Get-GitHubRawBaseUrl {
  $origin = Get-GitOutput -CommandArgs @("remote", "get-url", "origin")
  if ([string]::IsNullOrWhiteSpace($origin)) {
    return ""
  }

  $normalized = $origin.Trim()
  if ($normalized.EndsWith(".git")) {
    $normalized = $normalized.Substring(0, $normalized.Length - 4)
  }

  $owner = ""
  $repo = ""

  if ($normalized -match "^https?://github\.com/([^/]+)/([^/]+)$") {
    $owner = $matches[1]
    $repo = $matches[2]
  } elseif ($normalized -match "^git@github\.com:([^/]+)/([^/]+)$") {
    $owner = $matches[1]
    $repo = $matches[2]
  } else {
    return ""
  }

  if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
    return ""
  }

  $branch = Get-BranchName
  return "https://raw.githubusercontent.com/$owner/$repo/$branch"
}

function Get-FolderForAuthor {
  param(
    [string]$Author,
    [hashtable]$FolderMap
  )

  foreach ($folder in $FolderMap.Keys) {
    $entry    = $FolderMap[$folder]
    $entryVal = Get-ObjectPropertyValue -Object $entry -Name "author"
    if (-not [string]::IsNullOrWhiteSpace($entryVal) -and $entryVal.Trim() -eq $Author) {
      return $folder
    }
  }

  return ""
}

function Get-MainFolder {
  param(
    [string]$RelativePath
  )

  $parts = $RelativePath -split "/"
  if ($parts.Length -gt 1) {
    return $parts[0]
  }

  return ""
}

function Get-ThemeSearchRoots {
  param(
    [string]$RepoRoot,
    $AuthorMetadata
  )

  $roots = [System.Collections.Generic.List[string]]::new()
  $seen = @{}

  $foldersFromMetadata = @()
  if ($null -ne $AuthorMetadata -and $null -ne $AuthorMetadata.FolderMap) {
    $foldersFromMetadata = @($AuthorMetadata.FolderMap.Keys | Sort-Object)
  }

  foreach ($folder in $foldersFromMetadata) {
    if ([string]::IsNullOrWhiteSpace($folder)) { continue }

    $candidate = Join-Path $RepoRoot $folder
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }

    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    if (-not $seen.ContainsKey($fullPath)) {
      $seen[$fullPath] = $true
      $roots.Add($fullPath)
    }
  }

  $topLevelThemeDirs = Get-ChildItem -LiteralPath $RepoRoot -Directory | Where-Object { $_.Name -like "* Themes" }
  foreach ($dir in $topLevelThemeDirs) {
    $fullPath = [System.IO.Path]::GetFullPath($dir.FullName)
    if (-not $seen.ContainsKey($fullPath)) {
      $seen[$fullPath] = $true
      $roots.Add($fullPath)
    }
  }

  if ($roots.Count -eq 0) {
    $roots.Add([System.IO.Path]::GetFullPath($RepoRoot))
  }

  return @($roots | Sort-Object)
}

function Get-ThemeCssFiles {
  param(
    [string]$RepoRoot,
    $AuthorMetadata
  )

  $searchRoots = Get-ThemeSearchRoots -RepoRoot $RepoRoot -AuthorMetadata $AuthorMetadata
  $filesByPath = @{}

  foreach ($root in $searchRoots) {
    $rootPrefix = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.css" | Where-Object {
      ($_.FullName.Substring($rootPrefix.Length) -split '[/\\]')[0] -ne 'assists'
    }
    foreach ($file in $files) {
      $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
      if (-not $filesByPath.ContainsKey($fullPath)) {
        $filesByPath[$fullPath] = $file
      }
    }
  }

  return @($filesByPath.Values | Sort-Object FullName)
}

function Get-ObjectPropertyValue {
  param(
    $Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) {
      return $Object[$Name]
    }

    return $null
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -ne $property) {
    return $property.Value
  }

  return $null
}

function Convert-ToDictionary {
  param(
    $Object
  )

  $dictionary = @{}

  if ($null -eq $Object) {
    return $dictionary
  }

  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($key in $Object.Keys) {
      $dictionary[[string]$key] = $Object[$key]
    }

    return $dictionary
  }

  foreach ($property in $Object.PSObject.Properties) {
    $dictionary[$property.Name] = $property.Value
  }

  return $dictionary
}

function Read-AuthorMetadata {
  param(
    [string]$RepoRoot,
    [string]$MetadataPath
  )

  $resolvedPath = if ([System.IO.Path]::IsPathRooted($MetadataPath)) {
    $MetadataPath
  } else {
    Join-Path $RepoRoot $MetadataPath
  }

  $result = [PSCustomObject]@{
    Path          = $resolvedPath
    SchemaVersion = $null
    FolderMap     = @{}
    IsLoaded      = $false
  }

  if (-not (Test-Path -LiteralPath $resolvedPath)) {
    Write-Warning "Author metadata file not found: $resolvedPath"
    return $result
  }

  try {
    $rawJson = Get-Content -LiteralPath $resolvedPath -Raw
    $json = $rawJson | ConvertFrom-Json
  } catch {
    Write-Warning "Failed to parse author metadata '$resolvedPath': $($_.Exception.Message)"
    return $result
  }

  $result.SchemaVersion = Get-ObjectPropertyValue -Object $json -Name "schemaVersion"
  $folders = Get-ObjectPropertyValue -Object $json -Name "folders"
  $result.FolderMap = Convert-ToDictionary -Object $folders
  $result.IsLoaded = $true

  return $result
}

function Resolve-AuthorFromMetadata {
  param(
    [string]$MainFolder,
    [hashtable]$FolderMap
  )

  if ([string]::IsNullOrWhiteSpace($MainFolder)) {
    return ""
  }

  if (-not $FolderMap.ContainsKey($MainFolder)) {
    return ""
  }

  $folderEntry = $FolderMap[$MainFolder]
  if ($null -eq $folderEntry) {
    return ""
  }

  $authorsValue = Get-ObjectPropertyValue -Object $folderEntry -Name "authors"
  if ($null -ne $authorsValue) {
    $authors = [System.Collections.Generic.List[string]]::new()

    if ($authorsValue -is [string]) {
      $candidate = $authorsValue.Trim()
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $authors.Add($candidate)
      }
    } elseif ($authorsValue -is [System.Collections.IEnumerable]) {
      foreach ($item in $authorsValue) {
        if ($null -eq $item) { continue }

        $candidate = ([string]$item).Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
          $authors.Add($candidate)
        }
      }
    }

    if ($authors.Count -gt 0) {
      return ($authors -join ", ")
    }
  }

  $authorValue = Get-ObjectPropertyValue -Object $folderEntry -Name "author"
  if ($null -ne $authorValue) {
    $authorText = ([string]$authorValue).Trim()
    if (-not [string]::IsNullOrWhiteSpace($authorText)) {
      return $authorText
    }
  }

  return ""
}

function Get-UniqueAuthors {
  param(
    [string[]]$Authors
  )

  $result = [System.Collections.Generic.List[string]]::new()
  foreach ($author in $Authors) {
    if ([string]::IsNullOrWhiteSpace($author)) { continue }

    $trimmed = $author.Trim()
    if (-not ($result -contains $trimmed)) {
      $result.Add($trimmed)
    }
  }

  return @($result)
}

function Get-AuthorsFromFolderEntry {
  param(
    $FolderEntry
  )

  if ($null -eq $FolderEntry) {
    return @()
  }

  $authors = [System.Collections.Generic.List[string]]::new()

  $authorsValue = Get-ObjectPropertyValue -Object $FolderEntry -Name "authors"
  if ($null -ne $authorsValue) {
    if ($authorsValue -is [string]) {
      $authors.Add($authorsValue)
    } elseif ($authorsValue -is [System.Collections.IEnumerable]) {
      foreach ($item in $authorsValue) {
        if ($null -eq $item) { continue }
        $authors.Add([string]$item)
      }
    }
  }

  $authorValue = Get-ObjectPropertyValue -Object $FolderEntry -Name "author"
  if ($null -ne $authorValue) {
    $authors.Add([string]$authorValue)
  }

  return @(Get-UniqueAuthors -Authors @($authors))
}

function Build-FolderEntryFromAuthors {
  param(
    [string[]]$Authors
  )

  $uniqueAuthors = @(Get-UniqueAuthors -Authors $Authors)
  if ($uniqueAuthors.Count -le 0) {
    return [ordered]@{}
  }

  if ($uniqueAuthors.Count -eq 1) {
    return [ordered]@{
      author = $uniqueAuthors[0]
    }
  }

  return [ordered]@{
    authors = $uniqueAuthors
  }
}

function Get-KnownAuthorsFromFolderMap {
  param(
    [hashtable]$FolderMap
  )

  $authors = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in $FolderMap.Values) {
    foreach ($author in (Get-AuthorsFromFolderEntry -FolderEntry $entry)) {
      if (-not ($authors -contains $author)) {
        $authors.Add($author)
      }
    }
  }

  return @($authors | Sort-Object)
}

function Save-AuthorMetadata {
  param(
    [string]$Path,
    $SchemaVersion,
    [hashtable]$FolderMap
  )

  $schema = if ($null -eq $SchemaVersion) { 1 } else { $SchemaVersion }
  $foldersOut = [ordered]@{}

  foreach ($folder in ($FolderMap.Keys | Sort-Object)) {
    $entry = Build-FolderEntryFromAuthors -Authors (Get-AuthorsFromFolderEntry -FolderEntry $FolderMap[$folder])
    if ($entry.Keys.Count -eq 0) { continue }
    $foldersOut[$folder] = $entry
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("{")
  $lines.Add("  `"schemaVersion`": $schema,")

  if ($foldersOut.Count -eq 0) {
    $lines.Add("  `"folders`": {}")
    $lines.Add("}")
    Write-Utf8BomFile -Path $Path -Content ($lines -join [Environment]::NewLine)
    return
  }

  $lines.Add("  `"folders`": {")
  $folderKeys = @($foldersOut.Keys)

  for ($i = 0; $i -lt $folderKeys.Count; $i++) {
    $folder = $folderKeys[$i]
    $folderEntry = $foldersOut[$folder]
    $folderJson = $folder | ConvertTo-Json -Compress
    $folderComma = if ($i -lt ($folderKeys.Count - 1)) { "," } else { "" }

    $lines.Add("    ${folderJson}: {")

    if ($folderEntry.Contains("authors")) {
      $authorsJson = $folderEntry["authors"] | ConvertTo-Json -Compress
      $lines.Add("      `"authors`": $authorsJson")
    } else {
      $authorJson = $folderEntry["author"] | ConvertTo-Json -Compress
      $lines.Add("      `"author`": $authorJson")
    }

    $lines.Add("    }$folderComma")
  }

  $lines.Add("  }")
  $lines.Add("}")

  $json = $lines -join [Environment]::NewLine
  Write-Utf8BomFile -Path $Path -Content $json
}

function Read-YesNo {
  param(
    [string]$Prompt,
    [bool]$DefaultYes = $true
  )

  while ($true) {
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $input = (Read-Host "$Prompt $suffix").Trim()

    if ([string]::IsNullOrWhiteSpace($input)) {
      return $DefaultYes
    }

    switch ($input.ToLowerInvariant()) {
      "y" { return $true }
      "yes" { return $true }
      "n" { return $false }
      "no" { return $false }
      default {
        Write-Host "Please answer y or n."
      }
    }
  }
}

function Prompt-ForAuthorSelection {
  param(
    [string]$Folder,
    [string[]]$KnownAuthors
  )

  $options = @($KnownAuthors | Sort-Object -Unique)

  while ($true) {
    Write-Host ""
    Write-Host "Choose owner for folder '$Folder':"
    for ($i = 0; $i -lt $options.Count; $i++) {
      Write-Host "$($i + 1)) $($options[$i])"
    }
    Write-Host "N) New author"

    $choice = (Read-Host "Pick 1-$($options.Count) or N").Trim()
    if ([string]::IsNullOrWhiteSpace($choice)) {
      continue
    }

    if ($choice -match "^[nN]$") {
      while ($true) {
        $newAuthor = (Read-Host "Enter new author name").Trim()
        if (-not [string]::IsNullOrWhiteSpace($newAuthor)) {
          return $newAuthor
        }
        Write-Host "Author name can't be empty."
      }
    }

    if ($choice -match "^\d+$") {
      $index = [int]$choice
      if ($index -ge 1 -and $index -le $options.Count) {
        return $options[$index - 1]
      }
    }

    Write-Host "Invalid choice."
  }
}

function Get-DetectedAuthorsByFolder {
  param(
    [System.IO.FileInfo[]]$CssFiles,
    [string]$RepoRoot
  )

  $detected = @{}

  foreach ($file in $CssFiles) {
    $relativePath = To-RelativePath -Root $RepoRoot -Path $file.FullName
    $mainFolder = Get-MainFolder -RelativePath $relativePath
    if ([string]::IsNullOrWhiteSpace($mainFolder)) { continue }

    if (-not $detected.ContainsKey($mainFolder)) {
      $detected[$mainFolder] = [System.Collections.Generic.List[string]]::new()
    }

    $raw = Get-Content -LiteralPath $file.FullName -Raw
    $author = Get-MetadataValue -Raw $raw -Key "author"
    if (-not [string]::IsNullOrWhiteSpace($author)) {
      $trimmed = $author.Trim()
      if (-not ($detected[$mainFolder] -contains $trimmed)) {
        $detected[$mainFolder].Add($trimmed)
      }
    }
  }

  $result = @{}
  foreach ($folder in $detected.Keys) {
    $result[$folder] = @($detected[$folder] | Sort-Object)
  }

  return $result
}

function Ensure-AuthorMappings {
  param(
    [System.IO.FileInfo[]]$CssFiles,
    [string]$RepoRoot,
    $AuthorMetadata,
    [switch]$SkipPrompt
  )

  $foldersInCss = @(
    $CssFiles |
    ForEach-Object {
      $relativePath = To-RelativePath -Root $RepoRoot -Path $_.FullName
      Get-MainFolder -RelativePath $relativePath
    } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique
  )

  $missingFolders = @(
    $foldersInCss |
    Where-Object { -not $AuthorMetadata.FolderMap.ContainsKey($_) }
  )

  $staleFolders = @(
    $AuthorMetadata.FolderMap.Keys |
    Where-Object { $foldersInCss -notcontains $_ } |
    Sort-Object
  )

  if ($missingFolders.Count -eq 0 -and $staleFolders.Count -eq 0) {
    return $false
  }

  $metadataChanged = $false

  foreach ($folder in $staleFolders) {
    if ($SkipPrompt) {
      $AuthorMetadata.FolderMap.Remove($folder)
      $metadataChanged = $true
      continue
    }

    Write-Host ""
    Write-Host "Main folder missing from CSS scan: $folder"
    $removeFolder = Read-YesNo -Prompt "Remove this folder from theme-authors.json?" -DefaultYes $true
    if ($removeFolder) {
      $AuthorMetadata.FolderMap.Remove($folder)
      $metadataChanged = $true
    }
  }

  $detectedAuthorsByFolder = Get-DetectedAuthorsByFolder -CssFiles $CssFiles -RepoRoot $RepoRoot
  $knownAuthors = [System.Collections.Generic.List[string]]::new()
  foreach ($author in (Get-KnownAuthorsFromFolderMap -FolderMap $AuthorMetadata.FolderMap)) {
    $knownAuthors.Add($author)
  }

  foreach ($folder in $missingFolders) {
    $detectedAuthors = @()
    if ($detectedAuthorsByFolder.ContainsKey($folder)) {
      $detectedAuthors = @($detectedAuthorsByFolder[$folder])
    }

    if ($SkipPrompt) {
      if ($detectedAuthors.Count -gt 0) {
        $AuthorMetadata.FolderMap[$folder] = Build-FolderEntryFromAuthors -Authors $detectedAuthors
        $metadataChanged = $true
      }
      continue
    }

    Write-Host ""
    Write-Host "New main folder detected: $folder"
    if ($detectedAuthors.Count -gt 0) {
      Write-Host "Detected CSS author value(s): $($detectedAuthors -join ', ')"
      $useDetected = Read-YesNo -Prompt "Use detected author value(s) for this folder?" -DefaultYes $true
      if ($useDetected) {
        $AuthorMetadata.FolderMap[$folder] = Build-FolderEntryFromAuthors -Authors $detectedAuthors
        $metadataChanged = $true

        foreach ($author in $detectedAuthors) {
          if (-not ($knownAuthors -contains $author)) {
            $knownAuthors.Add($author)
          }
        }
        continue
      }
    } else {
      Write-Host "No CSS @author value found in this folder."
    }

    $selectedAuthor = Prompt-ForAuthorSelection -Folder $folder -KnownAuthors @($knownAuthors)
    $AuthorMetadata.FolderMap[$folder] = Build-FolderEntryFromAuthors -Authors @($selectedAuthor)
    $metadataChanged = $true

    if (-not ($knownAuthors -contains $selectedAuthor)) {
      $knownAuthors.Add($selectedAuthor)
    }
  }

  if ($metadataChanged) {
    Save-AuthorMetadata -Path $AuthorMetadata.Path -SchemaVersion $AuthorMetadata.SchemaVersion -FolderMap $AuthorMetadata.FolderMap
    Write-Output "Updated author metadata: $($AuthorMetadata.Path)"
  }

  return $metadataChanged
}

$repoRoot = Get-RepoRoot
$outputFile = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath
} else {
  Join-Path $repoRoot $OutputPath
}
$rawBaseUrl  = Get-GitHubRawBaseUrl
$blobBaseUrl = ""
if ($rawBaseUrl -match '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)$') {
  $blobBaseUrl = "https://github.com/$($matches[1])/$($matches[2])/blob/$($matches[3])"
}

if (-not [string]::IsNullOrWhiteSpace($PredictPngRawUrl)) {
  if ([string]::IsNullOrWhiteSpace($rawBaseUrl)) {
    [Console]::Error.WriteLine("Error: Couldn't determine GitHub raw base URL from git origin.")
    exit 1
  }

  try {
    $relativePngPath = Get-RepoRelativePath -RepoRoot $repoRoot -InputPath $PredictPngRawUrl
  } catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 1
  }

  if ([string]::IsNullOrWhiteSpace($relativePngPath)) {
    [Console]::Error.WriteLine("Error: Please provide a PNG path.")
    exit 1
  }

  if (-not $relativePngPath.ToLowerInvariant().EndsWith(".png")) {
    Write-Warning "Path is not a .png file. Generating URL anyway."
  }

  $encodedPngPath = Get-LinkPath -RelativePath $relativePngPath
  Write-Output "$rawBaseUrl/$encodedPngPath"
  return
}

$authorMetadata = Read-AuthorMetadata -RepoRoot $repoRoot -MetadataPath $MetadataPath

$cssFiles = Get-ThemeCssFiles -RepoRoot $repoRoot -AuthorMetadata $authorMetadata

if ($Doctor) {
  $doctorFailures = [System.Collections.Generic.List[string]]::new()
  $doctorWarnings = [System.Collections.Generic.List[string]]::new()
  $requiredHeaders = @("name", "author", "version", "description")
  $searchRoots = Get-ThemeSearchRoots -RepoRoot $repoRoot -AuthorMetadata $authorMetadata

  # Scope to a specific contributor folder if -Folder was provided
  if (-not [string]::IsNullOrWhiteSpace($Folder)) {
    $scopedFolderPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Folder))
    $cssFiles = @($cssFiles | Where-Object {
      $_.FullName.StartsWith($scopedFolderPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
      $_.FullName -eq $scopedFolderPath
    })
    $searchRoots = @($searchRoots | Where-Object {
      $_.StartsWith($scopedFolderPath, [System.StringComparison]::OrdinalIgnoreCase)
    })
    Write-Output "Scoped to folder: $Folder"
  }

  if (-not $authorMetadata.IsLoaded) {
    $doctorFailures.Add("Author metadata file is missing or invalid: $($authorMetadata.Path)")
  }

  if ([string]::IsNullOrWhiteSpace($rawBaseUrl)) {
    $doctorWarnings.Add("Couldn't determine GitHub raw base URL from git origin.")
  }

  if ($cssFiles.Count -eq 0) {
    $doctorFailures.Add("No CSS files found under theme roots$(if (-not [string]::IsNullOrWhiteSpace($Folder)) { " for folder '$Folder'" }).")
  }

  foreach ($file in $cssFiles) {
    $raw = Get-Content -LiteralPath $file.FullName -Raw
    $missingHeaders = [System.Collections.Generic.List[string]]::new()

    foreach ($header in $requiredHeaders) {
      $value = Get-MetadataValue -Raw $raw -Key $header
      if ([string]::IsNullOrWhiteSpace($value)) {
        $missingHeaders.Add("@$header")
      }
    }

    if ($missingHeaders.Count -gt 0) {
      $relativePath = To-RelativePath -Root $repoRoot -Path $file.FullName
      $doctorWarnings.Add("$relativePath missing metadata: $($missingHeaders -join ', ')")
    }
  }

  $foldersInCss = @(
    $cssFiles |
    ForEach-Object {
      $relativePath = To-RelativePath -Root $repoRoot -Path $_.FullName
      Get-MainFolder -RelativePath $relativePath
    } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique
  )

  $missingFolders = @(
    $foldersInCss |
    Where-Object { -not $authorMetadata.FolderMap.ContainsKey($_) }
  )

  $staleFolders = @(
    $authorMetadata.FolderMap.Keys |
    Where-Object { $foldersInCss -notcontains $_ } |
    Sort-Object
  )

  foreach ($folder in $missingFolders) {
    $doctorWarnings.Add("theme-authors.json missing mapping for folder: $folder")
  }

  foreach ($folder in $staleFolders) {
    $doctorWarnings.Add("theme-authors.json has stale folder mapping: $folder")
  }

  # AUTHOR.md check — optional file, but validate it if present
  $foldersToCheckMd = if (-not [string]::IsNullOrWhiteSpace($Folder)) {
    @($Folder)
  } else {
    @($foldersInCss | Sort-Object -Unique)
  }

  foreach ($folderName in $foldersToCheckMd) {
    $folderPath = Join-Path $repoRoot $folderName
    if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) { continue }

    $authorMdPath = Join-Path $folderPath "AUTHOR.md"
    if (Test-Path -LiteralPath $authorMdPath) {
      $mdContent = Get-Content -LiteralPath $authorMdPath -Raw
      if ([string]::IsNullOrWhiteSpace($mdContent)) {
        $doctorWarnings.Add("$folderName/AUTHOR.md exists but is empty")
      } else {
        $h1Match = [regex]::Match($mdContent, '(?m)^#\s+(.+)$')
        if (-not $h1Match.Success) {
          $doctorWarnings.Add("$folderName/AUTHOR.md is missing an H1 heading (e.g. '# Your Name') — this is used as your display name in the README")
        } else {
          $h1Text = $h1Match.Groups[1].Value.Trim()
          if ($h1Text.Length -gt 24) {
            $doctorWarnings.Add("$folderName/AUTHOR.md H1 heading '$h1Text' is $($h1Text.Length) characters — must be 24 or fewer")
          }
        }
      }
    }

    # Warn if any .md exists in the folder root with the wrong name
    $mdFiles = @(Get-ChildItem -LiteralPath $folderPath -File -Filter "*.md" -ErrorAction SilentlyContinue)
    foreach ($md in $mdFiles) {
      if ($md.Name -ne "AUTHOR.md") {
        $doctorWarnings.Add("$folderName/$($md.Name) — markdown files must be named AUTHOR.md")
      }
    }
  }

  Write-Output "Doctor report"
  Write-Output "Repo root: $repoRoot"
  Write-Output "Theme roots scanned: $($searchRoots.Count)"
  foreach ($root in $searchRoots) {
    $relativeRoot = To-RelativePath -Root $repoRoot -Path $root
    if ([string]::IsNullOrWhiteSpace($relativeRoot)) {
      $relativeRoot = "."
    }
    Write-Output "  - $relativeRoot"
  }
  Write-Output "CSS files found: $($cssFiles.Count)"
  Write-Output "Metadata file: $($authorMetadata.Path)"

  if ($doctorWarnings.Count -gt 0) {
    Write-Output ""
    Write-Output "Warnings:"
    foreach ($warning in $doctorWarnings) {
      Write-Output "  - $warning"
    }
  }

  if ($doctorFailures.Count -gt 0) {
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("Failures:")
    foreach ($failure in $doctorFailures) {
      [Console]::Error.WriteLine("  - $failure")
    }
    [Console]::Error.WriteLine("Doctor status: FAIL")
    exit 1
  }

  Write-Output ""
  if ($doctorWarnings.Count -gt 0) {
    Write-Output "Doctor status: WARN"
  } else {
    Write-Output "Doctor status: PASS"
  }

  return
}

$null = Ensure-AuthorMappings -CssFiles $cssFiles -RepoRoot $repoRoot -AuthorMetadata $authorMetadata -SkipPrompt:$NoAuthorPrompt

$themes = [System.Collections.Generic.List[object]]::new()
$fallbackByFolder = @{}

foreach ($file in $cssFiles) {
  $raw = Get-Content -LiteralPath $file.FullName -Raw
  $relativePath = To-RelativePath -Root $repoRoot -Path $file.FullName
  $mainFolder = Get-MainFolder -RelativePath $relativePath

  $name = Get-MetadataValue -Raw $raw -Key "name"
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = $file.BaseName
  }

  $authorFromFolder = Resolve-AuthorFromMetadata -MainFolder $mainFolder -FolderMap $authorMetadata.FolderMap
  $authorFromHeader = Get-MetadataValue -Raw $raw -Key "author"
  $hasFolderMapping = $authorMetadata.FolderMap.ContainsKey($mainFolder)

  $usedFallback = $false
  $fallbackReason = ""

  if (-not [string]::IsNullOrWhiteSpace($authorFromFolder)) {
    $author = $authorFromFolder
  } elseif (-not [string]::IsNullOrWhiteSpace($authorFromHeader)) {
    $author = $authorFromHeader
    $usedFallback = $true
    if ($hasFolderMapping) {
      $fallbackReason = "Folder mapping exists but has no usable author/authors value."
    } else {
      $fallbackReason = "No folder mapping found; used CSS @author fallback."
    }
  } else {
    $author = "Unknown"
    $usedFallback = $true
    if ($hasFolderMapping) {
      $fallbackReason = "Folder mapping exists but has no usable author/authors value, and CSS @author is missing."
    } else {
      $fallbackReason = "No folder mapping found and CSS @author is missing."
    }
  }

  if (
    $usedFallback -and
    -not [string]::IsNullOrWhiteSpace($mainFolder) -and
    -not $fallbackByFolder.ContainsKey($mainFolder)
  ) {
    $fallbackByFolder[$mainFolder] = [PSCustomObject]@{
      Folder         = $mainFolder
      FallbackAuthor = $author
      Reason         = $fallbackReason
    }
  }

  $theme = [PSCustomObject]@{
    Name        = $name
    Author      = $author
    Version     = Get-MetadataValue -Raw $raw -Key "version"
    Description = Get-MetadataValue -Raw $raw -Key "description"
    Path        = $relativePath
    LinkPath    = Get-LinkPath -RelativePath $relativePath
    RawUrl      = if ([string]::IsNullOrWhiteSpace($rawBaseUrl)) { "" } else { "$rawBaseUrl/$(Get-LinkPath -RelativePath $relativePath)" }
    MainFolder  = $mainFolder
    UsedFallback = $usedFallback
  }

  $themes.Add($theme)
}

$readmeLines = [System.Collections.Generic.List[string]]::new()
$sortedThemes = $themes | Sort-Object Author, Name
$authorGroups = $sortedThemes | Group-Object Author
$fallbackFolders = @($fallbackByFolder.Values | Sort-Object Folder)

# Dynamic counts for the welcome section
$themeCount       = $sortedThemes.Count
$contributorCount = @($authorGroups | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) -and $_.Name -ne "Unknown" }).Count
$themeWord        = if ($themeCount -ne 1) { "themes" } else { "theme" }
$contributorWord  = if ($contributorCount -ne 1) { "contributors" } else { "contributor" }

$readmeLines.Add("# discord-themes")
$readmeLines.Add("")
$readmeLines.Add("A community collection of custom Discord themes for BetterDiscord and Vencord — handcrafted by people who actually care about how their Discord looks.")
$readmeLines.Add("")
$readmeLines.Add("Currently home to **$themeCount $themeWord** from **$contributorCount $contributorWord**, and always open to more.")
$readmeLines.Add("")
$readmeLines.Add("---")
$readmeLines.Add("")
$readmeLines.Add("## How it works")
$readmeLines.Add("")
$readmeLines.Add("Every theme lives in its own contributor folder. Each contributor owns their folder — they can add, update, or remove their themes freely. Themes are installed via a raw GitHub URL, so you always get the latest version automatically without re-downloading anything.")
$readmeLines.Add("")
$readmeLines.Add("Contributors can also include an **AUTHOR.md** in their folder — a short profile page with links to their work, socials, and anything else relevant to their themes. Look for the **Profile** link next to a contributor's name in the Authors section below.")
$readmeLines.Add("")
$readmeLines.Add("---")
$readmeLines.Add("")
$readmeLines.Add("## Want to add your theme?")
$readmeLines.Add("")
$readmeLines.Add("This repo is open to everyone. If you've made a Discord theme and want it listed here, just fork the repo, add your theme, and open a pull request — the bot will validate it automatically and walk you through anything that needs fixing.")
$readmeLines.Add("")
$readmeLines.Add("Open a PR and the repo owner will review it. Once you're registered, future PRs auto-merge.")
$readmeLines.Add("")
$readmeLines.Add("→ **[Developer & Contributor Guide](https://github.com/Silverfox0338/discord-themes/wiki/Developer-&-Contributor-Guide)** — everything you need to know to submit a theme.")
$readmeLines.Add("")
$readmeLines.Add("---")
$readmeLines.Add("")
$readmeLines.Add("## Themes")
$readmeLines.Add("")
$readmeLines.Add("<details>")
$readmeLines.Add("<summary>$themeCount $themeWord — click to expand</summary>")
$readmeLines.Add("")
$readmeLines.Add("| Theme | Author | Version | Description | Raw URL/Online Theme URL |")
$readmeLines.Add("| --- | --- | --- | --- | --- |")

foreach ($theme in $sortedThemes) {
  $themeName        = Escape-TableCell -Value $theme.Name
  $themeAuthor      = Escape-TableCell -Value $theme.Author
  $themeVersion     = Escape-TableCell -Value $theme.Version
  $themeDescription = Escape-TableCell -Value $theme.Description
  $rawLink          = if ([string]::IsNullOrWhiteSpace($theme.RawUrl)) { "-" } else { "[Raw URL]($($theme.RawUrl))" }
  $localLink        = "[Online Theme URL]($($theme.LinkPath))"
  $combinedLinks    = "$rawLink / $localLink"

  $readmeLines.Add("| $themeName | $themeAuthor | $themeVersion | $themeDescription | $combinedLinks |")
}

$readmeLines.Add("")
$readmeLines.Add("</details>")
$readmeLines.Add("")
$readmeLines.Add("## Authors")

foreach ($group in $authorGroups) {
  $author       = if ([string]::IsNullOrWhiteSpace($group.Name)) { "Unknown" } else { $group.Name }
  $groupThemes  = @($group.Group | Sort-Object Name)
  $themeCount   = $groupThemes.Count
  $themeWord    = if ($themeCount -ne 1) { "themes" } else { "theme" }

  # Check for AUTHOR.md in this contributor's folder
  $authorFolder = Get-FolderForAuthor -Author $author -FolderMap $authorMetadata.FolderMap
  $authorMdLink = ""
  if (-not [string]::IsNullOrWhiteSpace($authorFolder) -and -not [string]::IsNullOrWhiteSpace($blobBaseUrl)) {
    $authorMdPath = Join-Path $repoRoot $authorFolder "AUTHOR.md"
    if (Test-Path -LiteralPath $authorMdPath) {
      $encodedFolder = Get-LinkPath -RelativePath $authorFolder
      $authorMdLink  = " · [Profile]($blobBaseUrl/$encodedFolder/AUTHOR.md)"
    }
  }

  $readmeLines.Add("")
  $readmeLines.Add("### $author$authorMdLink")
  $readmeLines.Add("")
  $readmeLines.Add("<details>")
  $readmeLines.Add("<summary>$themeCount $themeWord</summary>")
  $readmeLines.Add("")
  $readmeLines.Add("| Theme | Version | Description | Raw URL/Online Theme URL |")
  $readmeLines.Add("| --- | --- | --- | --- |")

  foreach ($theme in $groupThemes) {
    $themeName        = Escape-TableCell -Value $theme.Name
    $themeVersion     = Escape-TableCell -Value $theme.Version
    $themeDescription = Escape-TableCell -Value $theme.Description
    $rawLink          = if ([string]::IsNullOrWhiteSpace($theme.RawUrl)) { "-" } else { "[Raw URL]($($theme.RawUrl))" }
    $localLink        = "[Online Theme URL]($($theme.LinkPath))"
    $combinedLinks    = "$rawLink / $localLink"

    $readmeLines.Add("| $themeName | $themeVersion | $themeDescription | $combinedLinks |")
  }

  $readmeLines.Add("")
  $readmeLines.Add("Total themes: $themeCount")
  $readmeLines.Add("")
  $readmeLines.Add("</details>")
}

$readmeLines.Add("")
$readmeLines.Add("## Missing Folder Mappings")
$readmeLines.Add("")

if ($fallbackFolders.Count -eq 0) {
  $readmeLines.Add("None. All folders resolved authors from theme-authors.json.")
} else {
  $readmeLines.Add("| Folder | Fallback Author | Reason |")
  $readmeLines.Add("| --- | --- | --- |")

  foreach ($entry in $fallbackFolders) {
    $folder = Escape-TableCell -Value $entry.Folder
    $fallbackAuthor = Escape-TableCell -Value $entry.FallbackAuthor
    $reason = Escape-TableCell -Value $entry.Reason

    $readmeLines.Add("| $folder | $fallbackAuthor | $reason |")
  }
}

$content = ($readmeLines -join [Environment]::NewLine)
Write-Utf8BomFile -Path $outputFile -Content $content

Write-Output "README generated at $outputFile"
Write-Output "CSS files processed: $($themes.Count)"
Write-Output "Metadata file: $($authorMetadata.Path)"
Write-Output "Folders using fallback author resolution: $($fallbackFolders.Count)"