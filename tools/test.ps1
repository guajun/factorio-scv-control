[CmdletBinding()]
param(
  [string]$FactorioExe = $env:FACTORIO_EXE,
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$info = Get-Content -Raw -LiteralPath (Join-Path $projectRoot "info.json") | ConvertFrom-Json

function Get-SteamLibraryRoots {
  $roots = [System.Collections.Generic.List[string]]::new()
  $steamPath = (Get-ItemProperty -LiteralPath "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
  if (-not $steamPath) {
    $steamPath = Join-Path ${env:ProgramFiles(x86)} "Steam"
  }

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
  param([string]$ExplicitPath, [string]$TargetVersion)

  if ($ExplicitPath) {
    if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
      throw "Factorio executable not found: $ExplicitPath"
    }
    $candidate = (Resolve-Path -LiteralPath $ExplicitPath).Path
    $version = (Get-Item -LiteralPath $candidate).VersionInfo.ProductVersion
    if ($version -notlike "$TargetVersion.*") {
      throw "Factorio $TargetVersion is required; explicit executable reports $version."
    }
    return $candidate
  }

  $candidates = [System.Collections.Generic.List[string]]::new()
  foreach ($root in Get-SteamLibraryRoots) {
    $candidates.Add((Join-Path $root "steamapps\common\Factorio\bin\x64\factorio.exe"))
  }
  $candidates.Add((Join-Path $env:ProgramFiles "Factorio\bin\x64\factorio.exe"))

  foreach ($candidate in $candidates | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      continue
    }
    $version = (Get-Item -LiteralPath $candidate).VersionInfo.ProductVersion
    if ($version -like "$TargetVersion.*") {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  throw "Factorio $TargetVersion was not found. Pass -FactorioExe or set FACTORIO_EXE."
}

function Invoke-Factorio {
  param([string]$Executable, [string[]]$Arguments)

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) {
    $startInfo.ArgumentList.Add($argument)
  }

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $stdout.GetAwaiter().GetResult() | Write-Host
  $stderr.GetAwaiter().GetResult() | Write-Host
  if ($process.ExitCode -ne 0) {
    throw "Factorio exited with code $($process.ExitCode)."
  }
}

$factorio = Resolve-FactorioExecutable -ExplicitPath $FactorioExe -TargetVersion $info.factorio_version
$installRoot = Split-Path (Split-Path (Split-Path $factorio -Parent) -Parent) -Parent
$readData = Join-Path $installRoot "data"
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("factorio-scv-control-test-{0}" -f [guid]::NewGuid().ToString("N"))
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$safePrefix = $tempBase.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

if (-not $resolvedTestRoot.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path $resolvedTestRoot -Leaf) -notlike "factorio-scv-control-test-*") {
  throw "Refusing to use unsafe test path: $resolvedTestRoot"
}

try {
  $modsRoot = Join-Path $resolvedTestRoot "mods"
  $modRoot = Join-Path $modsRoot $info.name
  $writeData = Join-Path $resolvedTestRoot "write-data"
  $savePath = Join-Path $resolvedTestRoot "scv-control-test.zip"
  $configPath = Join-Path $resolvedTestRoot "config.ini"

  New-Item -ItemType Directory -Force -Path $modRoot, $writeData | Out-Null
  Get-ChildItem -Force -LiteralPath $projectRoot |
    Where-Object { $_.Name -notin ".git", ".github" } |
    Copy-Item -Destination $modRoot -Recurse -Force

  @{
    mods = @(
      @{name = "base"; enabled = $true},
      @{name = $info.name; enabled = $true}
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

  Write-Host "Creating an isolated test map with $factorio" -ForegroundColor Cyan
  Invoke-Factorio -Executable $factorio -Arguments @(
    "--config", $configPath,
    "--mod-directory", $modsRoot,
    "--create", $savePath,
    "--map-gen-seed", "12345",
    "--disable-audio"
  )

  if (-not (Test-Path -LiteralPath $savePath -PathType Leaf)) {
    throw "Factorio did not create the test save."
  }

  $createLog = Get-Content -Raw -LiteralPath (Join-Path $writeData "factorio-current.log")
  if ($createLog -notmatch "Loading mod $([regex]::Escape($info.name)) $([regex]::Escape($info.version))" -or
      $createLog -notmatch "Checksum for script __$([regex]::Escape($info.name))__/control.lua") {
    throw "Factorio did not load the expected mod version and control script."
  }

  Write-Host "Running 120 simulation ticks" -ForegroundColor Cyan
  Invoke-Factorio -Executable $factorio -Arguments @(
    "--config", $configPath,
    "--mod-directory", $modsRoot,
    "--benchmark", $savePath,
    "--benchmark-ticks", "120",
    "--benchmark-runs", "1",
    "--benchmark-sanitize",
    "--disable-audio"
  )

  Write-Host "PASS: $($info.name) $($info.version) loaded and ran on Factorio $($info.factorio_version)." -ForegroundColor Green
  if ($KeepArtifacts) {
    Write-Host "Artifacts: $resolvedTestRoot"
  }
}
finally {
  if (-not $KeepArtifacts -and (Test-Path -LiteralPath $resolvedTestRoot)) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
