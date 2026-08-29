[CmdletBinding()]
param(
  [ValidateSet("smoke", "integration", "all")]
  [string]$Suite = "all",
  [string]$FactorioExe = $env:FACTORIO_EXE,
  [int]$TimeoutSeconds = 90,
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testkitRoot = Join-Path $projectRoot "devmods\scv-control-testkit"
$info = Get-Content -Raw -LiteralPath (Join-Path $projectRoot "info.json") | ConvertFrom-Json
$testkitInfo = Get-Content -Raw -LiteralPath (Join-Path $testkitRoot "info.json") | ConvertFrom-Json

function Write-ModList {
  param([string]$ModsRoot)
  @{
    mods = @(
      @{name = "base"; enabled = $true},
      @{name = $info.name; enabled = $true},
      @{name = $testkitInfo.name; enabled = $true}
    )
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ModsRoot "mod-list.json") -Encoding utf8NoBOM
}

function Get-SteamLibraryRoots {
  $roots = [System.Collections.Generic.List[string]]::new()
  $steamPath = (Get-ItemProperty -LiteralPath "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
  if (-not $steamPath) { $steamPath = Join-Path ${env:ProgramFiles(x86)} "Steam" }
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

function Invoke-Factorio {
  param([string]$Executable, [string[]]$Arguments)
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $stdoutText = $stdout.GetAwaiter().GetResult()
  $stderrText = $stderr.GetAwaiter().GetResult()
  if ($stdoutText) { Write-Verbose $stdoutText }
  if ($stderrText) { Write-Verbose $stderrText }
  if ($process.ExitCode -ne 0) {
    if ($stdoutText) { Write-Host $stdoutText }
    if ($stderrText) { Write-Host $stderrText }
    throw "Factorio exited with code $($process.ExitCode)."
  }
}

function Invoke-SmokeSuite {
  param([string]$Executable, [string]$Config, [string]$Mods, [string]$WriteData, [string]$Root)
  $savePath = Join-Path $Root "smoke-test.zip"
  Write-Host "[smoke] Creating isolated map" -ForegroundColor Cyan
  Invoke-Factorio $Executable @(
    "--config", $Config,
    "--mod-directory", $Mods,
    "--create", $savePath,
    "--map-gen-seed", "12345",
    "--disable-audio"
  )
  if (-not (Test-Path -LiteralPath $savePath -PathType Leaf)) { throw "Smoke save was not created." }
  $log = Get-Content -Raw -LiteralPath (Join-Path $WriteData "factorio-current.log")
  if ($log -notmatch "Loading mod $([regex]::Escape($info.name)) $([regex]::Escape($info.version))" -or
      $log -notmatch "Checksum for script __$([regex]::Escape($info.name))__/control.lua") {
    throw "Smoke suite did not load the expected mod and control script."
  }

  Write-Host "[smoke] PASS: settings/data/control/on_init loaded and map saved" -ForegroundColor Green
}

function Invoke-IntegrationSuite {
  param([string]$Executable, [string]$Config, [string]$Mods, [string]$WriteData, [string]$Root)
  $serverSettings = Join-Path $Root "server-settings.json"
  @{
    name = "SCV Control Agent Test"
    description = "Temporary local integration test server."
    visibility = @{public = $false; lan = $false}
    auto_pause = $false
    autosave_interval = 0
  } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $serverSettings -Encoding utf8NoBOM

  $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $portProbe.Start()
  $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
  $portProbe.Stop()
  $startedAt = Get-Date
  $arguments = @(
    '--config', ('"{0}"' -f $Config),
    '--mod-directory', ('"{0}"' -f $Mods),
    '--start-server-load-scenario', "$($testkitInfo.name)/automated",
    '--server-settings', ('"{0}"' -f $serverSettings),
    '--port', "$port",
    '--disable-audio'
  )

  Write-Host "[integration] Starting automated scenario on port $port" -ForegroundColor Cyan
  $launcher = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $logPath = Join-Path $WriteData "factorio-current.log"
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $completed = $false
  try {
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 200
      if (-not (Test-Path -LiteralPath $logPath)) { continue }
      $log = Get-Content -Raw -LiteralPath $logPath
      if ($log -match "SCV_TESTKIT_COMPLETE") { $completed = $true; break }
      if ($log -match "non-recoverable error" -or $log -match "Error while running event") {
        throw "Integration scenario failed. See $logPath"
      }
    }
  }
  finally {
    Get-Process factorio -ErrorAction SilentlyContinue |
      Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-1) -and $_.Path -eq $Executable } |
      Stop-Process -Force -ErrorAction SilentlyContinue
    if (-not $launcher.HasExited) { Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue }
  }

  if (-not $completed) { throw "Integration suite timed out after $TimeoutSeconds seconds. See $logPath" }
  $reportPath = Join-Path $WriteData "script-output\scv-control\test-results.json"
  if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    throw "Integration suite completed without a JSON report. See $logPath"
  }
  $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
  foreach ($result in $report.results) {
    $label = if ($result.passed) { "PASS" } else { "FAIL" }
    Write-Host "[integration] $label $($result.name)"
  }
  if ($report.failed -gt 0) {
    throw "Integration suite failed: $($report.failed) failed, $($report.passed) passed. Report: $reportPath"
  }
  Write-Host "[integration] PASS: $($report.passed) assertions" -ForegroundColor Green
}

$factorio = Resolve-FactorioExecutable
$actualVersion = (Get-Item -LiteralPath $factorio).VersionInfo.ProductVersion
if ($actualVersion -notlike "$($info.factorio_version).*") {
  throw "Factorio $($info.factorio_version) is required; selected executable reports $actualVersion."
}

$installRoot = Split-Path (Split-Path (Split-Path $factorio -Parent) -Parent) -Parent
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("factorio-scv-agent-test-{0}" -f [guid]::NewGuid().ToString("N"))
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$safePrefix = $tempBase.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedTestRoot.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path $resolvedTestRoot -Leaf) -notlike "factorio-scv-agent-test-*") {
  throw "Refusing to use unsafe test path: $resolvedTestRoot"
}

$failed = $true
try {
  $modsRoot = Join-Path $resolvedTestRoot "mods"
  $writeData = Join-Path $resolvedTestRoot "write-data"
  $configPath = Join-Path $resolvedTestRoot "config.ini"
  New-Item -ItemType Directory -Force -Path $modsRoot, $writeData, (Join-Path $writeData "saves") | Out-Null
  New-Item -ItemType Junction -Path (Join-Path $modsRoot $info.name) -Target $projectRoot | Out-Null
  New-Item -ItemType Junction -Path (Join-Path $modsRoot $testkitInfo.name) -Target $testkitRoot | Out-Null
  Write-ModList $modsRoot

  $readDataConfig = (Join-Path $installRoot "data").Replace('\', '/')
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

  if ($Suite -in @("smoke", "all")) {
    Invoke-SmokeSuite $factorio $configPath $modsRoot $writeData $resolvedTestRoot
  }
  if ($Suite -in @("integration", "all")) {
    Invoke-IntegrationSuite $factorio $configPath $modsRoot $writeData $resolvedTestRoot
  }
  $failed = $false
  Write-Host "PASS: suite=$Suite Factorio=$actualVersion" -ForegroundColor Green
}
finally {
  if (($KeepArtifacts -or $failed) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
    Write-Host "Artifacts: $resolvedTestRoot"
  }
  elseif (Test-Path -LiteralPath $resolvedTestRoot) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
