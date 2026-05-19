# Local validation (no VPS). Run: .\scripts\validate-deploy-scripts.ps1
$ErrorActionPreference = 'Stop'
$deployDir = Split-Path $PSScriptRoot -Parent

$bash = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($bash) {
    foreach ($script in @('deploy.sh', 'finalize-release.sh', 'deploy-common.sh', 'deploy-config.sh')) {
        $path = Join-Path $deployDir $script
        & $bash -n $path
        if ($LASTEXITCODE -ne 0) { throw "bash -n failed: $script" }
        Write-Host "bash -n OK: $script"
    }
}
else {
    Write-Warning 'Git Bash not found; skip bash -n'
}

$ps1 = Join-Path $deployDir 'deploy-from-windows.ps1'
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$null, [ref]$parseErrors)
if ($parseErrors) {
    $parseErrors | ForEach-Object { Write-Error $_.ToString() }
}
Write-Host 'deploy-from-windows.ps1 parse OK'
Write-Host 'Validation complete.'
