# Choco + EnvVar Migrator (Export on Laptop A, Import on Laptop B)
# Run PowerShell as Administrator for best results.
# Usage:
#   Export: .\ChocoEnv-Migrate.ps1 -Mode Export -Dir "C:\temp\choco-migrate"
#   Import: .\ChocoEnv-Migrate.ps1 -Mode Import -Dir "C:\temp\choco-migrate"

param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("Export","Import")]
  [string]$Mode,

  [Parameter(Mandatory=$true)]
  [string]$Dir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir($path) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}

function Get-EnvHash([string]$scope) {
  $vars = [System.Environment]::GetEnvironmentVariables($scope)
  $hash = @{}
  foreach ($k in $vars.Keys) { $hash[$k] = [string]$vars[$k] }
  return $hash
}

function Merge-Path([string]$existing, [string]$incoming) {
  $split = {
    param([string]$p)
    @($p -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
  }

  $a = & $split $existing
  $b = & $split $incoming

  $set = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $out = New-Object System.Collections.Generic.List[string]

  foreach ($x in $a) { if ($set.Add($x)) { $out.Add($x) } }
  foreach ($x in $b) { if ($set.Add($x)) { $out.Add($x) } }

  return ($out -join ';')
}

function Apply-Env([string]$scope, $vars, [string]$userPathOverride) {
  foreach ($p in $vars.PSObject.Properties) {
    $name = $p.Name
    $value = [string]$p.Value

    if ($name -ieq "PATH") {
      $current = [System.Environment]::GetEnvironmentVariable("PATH", $scope)

      # If this is USER scope and a manual override was provided, use it.
      if ($scope -eq "User" -and $null -ne $userPathOverride -and $userPathOverride.Trim() -ne "") {
        $newPath = Merge-Path $current $userPathOverride
      } else {
        $newPath = Merge-Path $current $value
      }

      [System.Environment]::SetEnvironmentVariable("PATH", $newPath, $scope)
    }
    else {
      [System.Environment]::SetEnvironmentVariable($name, $value, $scope)
    }
  }
}

Ensure-Dir $Dir

if ($Mode -eq "Export") {

  Write-Host "=== EXPORT MODE ==="
  Write-Host "Export dir: $Dir"

  # 1) Export Chocolatey packages
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    choco export --output-file (Join-Path $Dir "packages.config")
    choco list -lo -r | Out-File (Join-Path $Dir "choco-installed.txt") -Encoding utf8
    Write-Host "Chocolatey export complete."
  } else {
    Write-Warning "Chocolatey (choco) not found. Skipping package export."
  }

  # 2) Export environment variables (User + Machine)
  $data = [ordered]@{
    ExportedAt    = (Get-Date).ToString("o")
    ComputerName  = $env:COMPUTERNAME
    User          = $env:USERNAME
    UserEnv       = (Get-EnvHash "User")
    MachineEnv    = (Get-EnvHash "Machine")
  }

  $jsonPath = Join-Path $Dir "envvars.json"
  $data | ConvertTo-Json -Depth 8 | Out-File $jsonPath -Encoding utf8
  Write-Host "Env var export complete: $jsonPath"

  Write-Host "Done."
  exit 0
}

if ($Mode -eq "Import") {

  Write-Host "=== IMPORT MODE ==="
  Write-Host "Import dir: $Dir"

  $pkgConfig = Join-Path $Dir "packages.config"
  $envJson   = Join-Path $Dir "envvars.json"

  # 1) Install Chocolatey packages from packages.config
  if (Test-Path $pkgConfig) {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
      choco install $pkgConfig -y
      Write-Host "Chocolatey install complete."
    } else {
      Write-Warning "Chocolatey (choco) not found. Install Chocolatey first, then re-run Import."
    }
  } else {
    Write-Warning "packages.config not found. Skipping package install."
  }

  # 2) Import env vars (User + Machine), PATH is merged (not replaced)
  if (-not (Test-Path $envJson)) {
    throw "envvars.json not found at: $envJson"
  }

  $json = Get-Content $envJson -Raw | ConvertFrom-Json

  # >>> EDIT USER PATH HERE <<<
  # Put ONLY the extra User PATH entries you want to add on this laptop.
  # Example:
  # $UserPathExtra = @(
  #   "C:\Tools\bin",
  #   "$env:USERPROFILE\AppData\Local\Programs\Python\Python312\Scripts"
  # ) -join ";"
  $UserPathExtra = ""   # <-- EDIT THIS LINE / BLOCK

  # Apply env vars
  Apply-Env "User"    $json.UserEnv    $UserPathExtra
  Apply-Env "Machine" $json.MachineEnv $null

  Write-Host "Imported env vars. Log off/on or reboot so apps pick up changes."
  Write-Host "Done."
  exit 0
}
