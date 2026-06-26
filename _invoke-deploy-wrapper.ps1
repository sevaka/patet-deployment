#Requires -Version 5.1
# Shared entry for deploy-patet.ps1 / deploy-commercial.ps1 (do not run directly).
param(
    [Parameter(Mandatory)]
    [ValidateSet('patet-am', 'commercial')]
    [string] $DeployProfile,

    [Parameter(Position = 0)]
    [ValidateSet('backend', 'frontend', 'all')]
    [string] $Target = 'all',

    [switch] $SkipBuild,
    [switch] $Migrate,
    [switch] $SkipUpload,
    [switch] $SyncDeploymentScripts,

    [string] $ReleaseId = ''
)

Set-Location -LiteralPath $PSScriptRoot

$forward = @{}
foreach ($key in $PSBoundParameters.Keys) {
    if ($key -eq 'DeployProfile') { continue }
    $forward[$key] = $PSBoundParameters[$key]
}
$forward['Profile'] = $DeployProfile

& (Join-Path $PSScriptRoot 'deploy-from-windows.ps1') @forward
