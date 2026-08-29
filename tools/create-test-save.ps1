[CmdletBinding()]
param(
  [string]$FactorioExe = $env:FACTORIO_EXE,
  [string]$Destination = (Join-Path $env:APPDATA "Factorio\saves\SCV Control Test.zip"),
  [switch]$Force,
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$info = Get-Content -Raw -LiteralPath (Join-Path $projectRoot "info.json") | ConvertFrom-Json
$testkitRoot = Join-Path $projectRoot "devmods\scv-control-testkit"
$testkitInfo = Get-Content -Raw -LiteralPath (Join-Path $testkitRoot "info.json") | ConvertFrom-Json

function Get-SteamLibraryRoots {
  $roots = [System.Collections.Generic.List[string]]::new()
  $steamPath = (Get-ItemProperty -LiteralPath "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
  if ($steamPath) {
    $roots.Add($steamPath)
    $libraryFile = Join-Path $steamPath "steamapps\libraryfolders.vdf"
    if (Test-Path -LiteralPath $libraryFile) {
      foreach ($line in Get-Content -LiteralPath $libraryFile) {
        if ($line -match '"path"\s+"([^"]+)"') {
          $roots.Add(($Matches[1] -replace '\\\\', '\'))
        }
      }
    }
  }
  return $roots | Select-Object -Unique
}

function Resolve-FactorioExecutable {
  if ($FactorioExe) {
    if (-not (Test-Path -LiteralPath $FactorioExe -PathType Leaf)) {
      throw "Factorio executable not found: $FactorioExe"
    }
    return (Resolve-Path -LiteralPath $FactorioExe).Path
  }

  $candidates = [System.Collections.Generic.List[string]]::new()
  foreach ($root in Get-SteamLibraryRoots) {
    $candidates.Add((Join-Path $root "steamapps\common\Factorio\bin\x64\factorio.exe"))
  }
  $candidates.Add((Join-Path $env:ProgramFiles "Factorio\bin\x64\factorio.exe"))

  foreach ($candidate in $candidates | Select-Object -Unique) {
    if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
        (Get-Item -LiteralPath $candidate).VersionInfo.ProductVersion -like "$($info.factorio_version).*") {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }
  throw "Factorio $($info.factorio_version) was not found. Pass -FactorioExe or set FACTORIO_EXE."
}

function Install-DevelopmentMod {
  $modsRoot = Join-Path $env:APPDATA "Factorio\mods"
  New-Item -ItemType Directory -Force -Path $modsRoot | Out-Null

  $developmentMods = @(
    @{name = $info.name; path = $projectRoot},
    @{name = $testkitInfo.name; path = $testkitRoot}
  )
  foreach ($developmentMod in $developmentMods) {
    $linkPath = Join-Path $modsRoot $developmentMod.name
    if (Test-Path -LiteralPath $linkPath) {
      $existing = Get-Item -LiteralPath $linkPath
      $targetMatches = $existing.LinkType -eq "Junction" -and
        $existing.Target -and
        ([IO.Path]::GetFullPath(@($existing.Target)[0]) -eq [IO.Path]::GetFullPath($developmentMod.path))
      if (-not $targetMatches) {
        throw "Mod path already exists and is not the expected project junction: $linkPath"
      }
    }
    else {
      New-Item -ItemType Junction -Path $linkPath -Target $developmentMod.path | Out-Null
    }
  }

  $modListPath = Join-Path $modsRoot "mod-list.json"
  if (Test-Path -LiteralPath $modListPath) {
    $modList = Get-Content -Raw -LiteralPath $modListPath | ConvertFrom-Json
  }
  else {
    $modList = [pscustomobject]@{mods = @([pscustomobject]@{name = "base"; enabled = $true})}
  }

  $entries = @($modList.mods)
  foreach ($modName in @($info.name, $testkitInfo.name)) {
    $entry = $entries | Where-Object name -EQ $modName | Select-Object -First 1
    if ($entry) {
      $entry.enabled = $true
    }
    else {
      $entries += [pscustomobject]@{name = $modName; enabled = $true}
    }
  }
  [pscustomobject]@{mods = $entries} |
    ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $modListPath -Encoding utf8NoBOM

  return $developmentMods | ForEach-Object { Join-Path $modsRoot $_.name }
}

$factorio = Resolve-FactorioExecutable
$actualVersion = (Get-Item -LiteralPath $factorio).VersionInfo.ProductVersion
if ($actualVersion -notlike "$($info.factorio_version).*") {
  throw "Factorio $($info.factorio_version) is required; selected executable reports $actualVersion."
}

$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) {
  if (-not $Force) {
    throw "Save already exists: $destinationPath. Use -Force to replace it."
  }
}

$installRoot = Split-Path (Split-Path (Split-Path $factorio -Parent) -Parent) -Parent
$readData = Join-Path $installRoot "data"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("factorio-scv-save-{0}" -f [guid]::NewGuid().ToString("N"))
$writeData = Join-Path $tempRoot "write-data"
$modsRoot = Join-Path $tempRoot "mods"
$scenarioSave = Join-Path $writeData "saves\SCV Control Test.zip"
$configPath = Join-Path $tempRoot "config.ini"
$serverSettingsPath = Join-Path $tempRoot "server-settings.json"
$logPath = Join-Path $writeData "factorio-current.log"
$serverProcess = $null
$startedAt = $null

try {
  New-Item -ItemType Directory -Force -Path $writeData, (Join-Path $writeData "saves"), $modsRoot | Out-Null
  New-Item -ItemType Junction -Path (Join-Path $modsRoot $info.name) -Target $projectRoot | Out-Null
  New-Item -ItemType Junction -Path (Join-Path $modsRoot $testkitInfo.name) -Target $testkitRoot | Out-Null
  @{
    mods = @(
      @{name = "base"; enabled = $true},
      @{name = $info.name; enabled = $true},
      @{name = $testkitInfo.name; enabled = $true}
    )
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $modsRoot "mod-list.json") -Encoding utf8NoBOM

  $readDataConfig = $readData.Replace('\', '/')
  $writeDataConfig = $writeData.Replace('\', '/')
  @"
[path]
read-data=$readDataConfig
write-data=$writeDataConfig

[general]
locale=en

[other]
enable-new-mods=true
"@ | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

  @{
    name = "SCV Control Test Save Builder"
    description = "Temporary local server used to build the SCV Control test save."
    visibility = @{public = $false; lan = $false}
    auto_pause = $false
    autosave_interval = 0
  } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $serverSettingsPath -Encoding utf8NoBOM

  $startedAt = Get-Date
  $arguments = @(
    '--config', ('"{0}"' -f $configPath),
    '--mod-directory', ('"{0}"' -f $modsRoot),
    '--start-server-load-scenario', "$($testkitInfo.name)/interactive",
    '--server-settings', ('"{0}"' -f $serverSettingsPath),
    '--disable-audio'
  )
  $serverProcess = Start-Process -FilePath $factorio -ArgumentList $arguments -WindowStyle Hidden -PassThru

  $deadline = (Get-Date).AddSeconds(90)
  $saveReady = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    if (Test-Path -LiteralPath $logPath) {
      $log = Get-Content -Raw -LiteralPath $logPath
      if ($log -match "non-recoverable error" -or $log -match "Error while running event") {
        throw "Scenario failed to initialize. See $logPath"
      }
    }
    if (Test-Path -LiteralPath $scenarioSave -PathType Leaf) {
      $firstSize = (Get-Item -LiteralPath $scenarioSave).Length
      Start-Sleep -Milliseconds 500
      $secondSize = (Get-Item -LiteralPath $scenarioSave).Length
      if ($firstSize -gt 0 -and $firstSize -eq $secondSize) {
        $saveReady = $true
        break
      }
    }
  }
  if (-not $saveReady) {
    throw "Timed out waiting for the scenario save. See $logPath"
  }

  $ownedProcesses = Get-Process factorio -ErrorAction SilentlyContinue |
    Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-1) -and $_.Path -eq $factorio }
  foreach ($process in $ownedProcesses) {
    Stop-Process -Id $process.Id -Force
  }

  New-Item -ItemType Directory -Force -Path (Split-Path $destinationPath -Parent) | Out-Null
  Copy-Item -LiteralPath $scenarioSave -Destination $destinationPath -Force:$Force
  $modLinks = Install-DevelopmentMod

  Write-Host "Created: $destinationPath" -ForegroundColor Green
  foreach ($modLink in $modLinks) {
    Write-Host "Development mod: $modLink" -ForegroundColor Green
  }
  Write-Host "Open Factorio, choose Load game, then SCV Control Test." -ForegroundColor Cyan
}
finally {
  if ($serverProcess -and -not $serverProcess.HasExited) {
    Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
  }
  if ($startedAt) {
    Get-Process factorio -ErrorAction SilentlyContinue |
      Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-1) -and $_.Path -eq $factorio } |
      Stop-Process -Force -ErrorAction SilentlyContinue
  }
  if (-not $KeepArtifacts -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  elseif ($KeepArtifacts) {
    Write-Host "Artifacts: $tempRoot"
  }
}
