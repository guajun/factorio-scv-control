[CmdletBinding()]
param(
  [string]$FactorioExe = $env:FACTORIO_EXE,
  [string]$PythonExe = "python",
  [int]$TimeoutSeconds = 180,
  [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$repository = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$evaluationRoot = Join-Path $temporaryBase ("scv-navigation-eval-" + [guid]::NewGuid().ToString("N"))
$evaluationRoot = [IO.Path]::GetFullPath($evaluationRoot)
$safePrefix = $temporaryBase.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $evaluationRoot.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path $evaluationRoot -Leaf) -notlike "scv-navigation-eval-*") {
  throw "Unsafe evaluation root: $evaluationRoot"
}

function Invoke-EvaluationCommand {
  param([string]$Executable, [string[]]$Arguments)
  $output = & $Executable @Arguments 2>&1
  $code = $LASTEXITCODE
  foreach ($line in $output) { Write-Host $line }
  if ($code -ne 0) { throw "Evaluation command failed with exit code ${code}: $Executable" }
  return ($output -join "`n")
}

function Invoke-Integration {
  param([string]$Project)
  $arguments = @("-NoProfile", "-File", (Join-Path $Project "tools/test.ps1"),
    "-Suite", "interchange", "-KeepArtifacts", "-TimeoutSeconds", "$TimeoutSeconds")
  if ($FactorioExe) { $arguments += @("-FactorioExe", $FactorioExe) }
  $output = Invoke-EvaluationCommand "pwsh" $arguments
  $match = [regex]::Match($output, '(?m)^Artifacts:\s*(.+)\r?$')
  if (-not $match.Success) { throw "Integration did not retain its report directory." }
  return $match.Groups[1].Value.Trim()
}

$failed = $true
try {
  New-Item -ItemType Directory -Path $evaluationRoot | Out-Null
  $testkitCopy = Join-Path $evaluationRoot "project"
  New-Item -ItemType Directory -Path $testkitCopy | Out-Null
  # Copy only project inputs; never edit generated imports in the user's checkout.
  foreach ($directory in @("scripts", "scenarios", "devmods", "tools", "locale")) {
    Copy-Item -LiteralPath (Join-Path $repository $directory) -Destination $testkitCopy -Recurse
  }
  foreach ($file in @("control.lua", "data.lua", "settings.lua", "info.json")) {
    Copy-Item -LiteralPath (Join-Path $repository $file) -Destination $testkitCopy
  }

  [void](Invoke-EvaluationCommand $PythonExe @("-m", "unittest", "discover", "-s", (Join-Path $repository "tools/navigation"), "-p", "test_*.py", "-v"))
  $captureRoot = Invoke-Integration $testkitCopy
  $capturePath = Join-Path $captureRoot "write-data/script-output/scv-control/navigation/fixture-v4-capture.json"
  if (-not (Test-Path -LiteralPath $capturePath)) { throw "Missing fixture capture: $capturePath" }
  Copy-Item -LiteralPath $capturePath -Destination (Join-Path $evaluationRoot "capture.json")
  $runs = @()
  foreach ($algorithm in @("dijkstra", "astar")) {
    $solverPath = Join-Path $evaluationRoot ($algorithm + ".json")
    $luaPath = Join-Path $testkitCopy "devmods/scv-control-testkit/interchange/imported_plans.lua"
    [void](Invoke-EvaluationCommand $PythonExe @((Join-Path $repository "tools/navigation/solve.py"),
      "--bundle", $capturePath, "--algorithm", $algorithm, "--output", $solverPath, "--lua-output", $luaPath))
    $replayRoot = Invoke-Integration $testkitCopy
    $runs += @{algorithm = $algorithm; solver_report = $solverPath; replay_root = $replayRoot}
  }
  $reference = Get-Content -LiteralPath $runs[0].solver_report -Raw | ConvertFrom-Json
  $candidate = Get-Content -LiteralPath $runs[1].solver_report -Raw | ConvertFrom-Json
  if ($reference.cases.Count -ne 11 -or $candidate.cases.Count -ne $reference.cases.Count) {
    throw "Comparison must preserve all 11 shared fixtures."
  }
  $comparison = @()
  for ($index = 0; $index -lt $reference.cases.Count; $index++) {
    $first, $second = $reference.cases[$index], $candidate.cases[$index]
    if ($first.id -ne $second.id -or $first.query.query_hash -ne $second.query.query_hash -or
        $first.result.outcome -ne $second.result.outcome) { throw "Mismatched comparison: $($first.id)" }
    if ($first.result.outcome -eq "complete" -and
        [Math]::Abs($first.result.predicted.distance - $second.result.predicted.distance) -gt 0.00000001) {
      throw "A* differs from Dijkstra on the identical graph: $($first.id)"
    }
    $comparison += @{id = $first.id; outcome = $first.result.outcome;
      distance = $first.result.predicted.distance; dijkstra_expansions = $first.result.metrics.expanded_nodes;
      astar_expansions = $second.result.metrics.expanded_nodes}
  }
  $report = @{schema = "scv-navigation-eval/1"; capture_root = $captureRoot; runs = $runs; comparison = $comparison}
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evaluationRoot "manifest.json") -Encoding utf8NoBOM
  $failed = $false
  Write-Host "SCV_NAV_EVAL_COMPLETE algorithms=2"
}
finally {
  if ($failed -or $KeepArtifacts) { Write-Host "Navigation eval artifacts: $evaluationRoot" }
  else {
    # The exact absolute root was validated before creation. Child integration roots
    # retain their reports and are intentionally not deleted by this wrapper.
    Remove-Item -LiteralPath $evaluationRoot -Recurse -Force
  }
}
