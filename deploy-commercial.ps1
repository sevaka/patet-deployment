#Requires -Version 5.1
<#
.SYNOPSIS
  Deploy to commercial SaaS (Server 2, e.g. parcel-ops.com) using profiles/commercial.env
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

    [string] $ReleaseId = ''
)

$wrapperArgs = @{ DeployProfile = 'commercial' }
foreach ($key in $PSBoundParameters.Keys) {
    $wrapperArgs[$key] = $PSBoundParameters[$key]
}

& (Join-Path $PSScriptRoot '_invoke-deploy-wrapper.ps1') @wrapperArgs
