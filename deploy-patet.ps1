#Requires -Version 5.1
<#
.SYNOPSIS
  Deploy to patet.am (Server 1) using profiles/patet-am.env
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('backend', 'frontend', 'all')]
    [string] $Target = 'all',

    [switch] $SkipBuild,
    [switch] $Migrate,
    [switch] $SkipUpload,
    [switch] $SyncDeploymentScripts,
    [switch] $ForceSyncVideos,

    [string] $ReleaseId = ''
)

$wrapperArgs = @{ DeployProfile = 'patet-am' }
foreach ($key in $PSBoundParameters.Keys) {
    $wrapperArgs[$key] = $PSBoundParameters[$key]
}

& (Join-Path $PSScriptRoot '_invoke-deploy-wrapper.ps1') @wrapperArgs
