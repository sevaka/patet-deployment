#Requires -Version 5.1
<#
.SYNOPSIS
  Build patet-back-nestjs and/or patet-website on Windows, upload to Ubuntu, finalize on server.

.DESCRIPTION
  Primary deploy path: local yarn build -> rsync/scp release -> finalize-release.sh on VPS.
  Fallback: push git to Bitbucket, SSH and run ./deploy.sh on the server (see README).

.PARAMETER Target
  backend | frontend | all

.PARAMETER SkipBuild
  Upload only (artifacts must already exist locally).

.PARAMETER SkipMigrate
  Pass --skip-migrate to server finalize (backend only).

.PARAMETER SkipUpload
  Build only; do not upload or finalize.

.PARAMETER ReleaseId
  Override release folder name (default: Asia/Yerevan-style timestamp yyyy-MM-dd_HHmmss).

.PARAMETER SyncDeploymentScripts
  Rsync patet-deployment scripts to PATET_DEPLOYMENT_ROOT on the server before finalize.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('backend', 'frontend', 'all')]
    [string] $Target = 'all',

    [switch] $SkipBuild,
    [switch] $SkipMigrate,
    [switch] $SkipUpload,
    [switch] $SyncDeploymentScripts,

    [string] $ReleaseId = ''
)

$ErrorActionPreference = 'Stop'

$DeploymentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackAndFrontRoot = Split-Path -Parent $DeploymentDir

function Write-Step([string] $Message) {
    Write-Host ""
    Write-Host "==== $Message ====" -ForegroundColor Cyan
}

function Import-DeployLocalEnv {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing $Path - copy deploy.local.env.example to deploy.local.env and set PATET_SSH_HOST / PATET_SSH_USER."
    }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { return }
        $name = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        Set-Item -Path "Env:$name" -Value $value
    }
}

function Resolve-RepoPath([string] $RelativeOrAbsolute) {
    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolute)) {
        return $RelativeOrAbsolute
    }
    return Join-Path $BackAndFrontRoot $RelativeOrAbsolute
}

function Get-ReleaseTimestamp {
    if ($ReleaseId) { return $ReleaseId }
    $now = [DateTime]::UtcNow
    try {
        $tz = [TimeZoneInfo]::FindSystemTimeZoneById('Asia/Yerevan')
        $now = [TimeZoneInfo]::ConvertTimeFromUtc($now, $tz)
    }
    catch {
        Write-Warning 'Timezone Asia/Yerevan not found; using UTC for release id.'
    }
    return $now.ToString('yyyy-MM-dd_HHmmss')
}

function Assert-Command([string] $Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Write-UploadShaFile {
    param(
        [string] $RepoPath
    )
    Assert-Command git
    Push-Location $RepoPath
    try {
        $sha = (git rev-parse HEAD).Trim()
        if ($sha -notmatch '^[a-f0-9]{7,40}$') {
            throw "git rev-parse HEAD returned unexpected value in $RepoPath"
        }
        Set-Content -LiteralPath (Join-Path $RepoPath '.patet-upload-sha') -Value $sha -NoNewline
        Write-Host "Wrote .patet-upload-sha ($sha)"
    }
    finally {
        Pop-Location
    }
}

function Invoke-YarnBuild {
    param(
        [string] $RepoPath,
        [ValidateSet('backend', 'frontend')]
        [string] $Kind
    )
    Write-Step "Building $Kind in $RepoPath"
    Push-Location $RepoPath
    try {
        Assert-Command yarn
        yarn install
        if ($Kind -eq 'frontend') {
            $env:NODE_ENV = 'production'
            foreach ($lock in @('package-lock.json', 'npm-shrinkwrap.json')) {
                $p = Join-Path $RepoPath $lock
                if (Test-Path $p) { Remove-Item $p -Force }
            }
        }
        yarn build
        if ($Kind -eq 'backend') {
            $mainJs = Join-Path $RepoPath 'dist\src\main.js'
            if (-not (Test-Path $mainJs)) {
                throw "Backend build missing dist\src\main.js"
            }
        }
        else {
            $buildId = Join-Path $RepoPath '.next\BUILD_ID'
            if (-not (Test-Path $buildId)) {
                throw "Frontend build missing .next\BUILD_ID"
            }
        }
        Write-UploadShaFile -RepoPath $RepoPath
    }
    finally {
        Pop-Location
    }
}

function Get-RsyncExecutable {
    if (Get-Command rsync -ErrorAction SilentlyContinue) { return 'rsync' }
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        return 'wsl'
    }
    return $null
}

function Invoke-RsyncRelease {
    param(
        [string] $LocalPath,
        [string] $RemotePath,
        [string] $SshTarget
    )
    $excludes = @(
        '--exclude', 'node_modules/',
        '--exclude', '.env',
        '--exclude', '.env.*',
        '--exclude', 'coverage/',
        '--exclude', '.cursor/',
        '--exclude', '*.log'
    )
    $rsync = Get-RsyncExecutable
    if (-not $rsync) {
        return $false
    }

    $localTrail = $LocalPath.TrimEnd('\') + [IO.Path]::DirectorySeparatorChar
    $remote = "${SshTarget}:${RemotePath}/"

    if ($rsync -eq 'wsl') {
        $wslLocal = wsl wslpath -a $localTrail
        $args = @(
            'rsync', '-avz', '--delete'
        ) + $excludes + @($wslLocal, $remote)
        Write-Host "wsl $($args -join ' ')"
        & wsl @args
    }
    else {
        $args = @('-avz', '--delete') + $excludes + @($localTrail, $remote)
        Write-Host "rsync $($args -join ' ')"
        & rsync @args
    }
    if ($LASTEXITCODE -ne 0) { throw "rsync failed with exit code $LASTEXITCODE" }
    return $true
}

function Invoke-ScpTarRelease {
    param(
        [string] $LocalPath,
        [string] $RemotePath,
        [string] $SshTarget
    )
    Write-Step "Uploading via tar+scp (rsync not available)"
    Assert-Command tar
    Assert-Command scp
    Assert-Command ssh

    $staging = Join-Path $env:TEMP ("patet-upload-" + [Guid]::NewGuid().ToString('N'))
    $archive = "$staging.tgz"
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        $tarArgs = @(
            '-czf', $archive,
            '--exclude=node_modules',
            '--exclude=.env',
            '--exclude=.env.*',
            '--exclude=coverage',
            '--exclude=.cursor',
            '-C', $LocalPath,
            '.'
        )
        & tar @tarArgs
        if ($LASTEXITCODE -ne 0) { throw "tar create failed" }

        $remoteParent = ($RemotePath -replace '/[^/]+$','')
        & ssh $SshTarget "mkdir -p '$remoteParent' '$RemotePath'"
        if ($LASTEXITCODE -ne 0) { throw "ssh mkdir failed" }

        & scp $archive "${SshTarget}:/tmp/patet-release.tgz"
        if ($LASTEXITCODE -ne 0) { throw "scp failed" }

        & ssh $SshTarget "rm -rf '$RemotePath' && mkdir -p '$RemotePath' && tar -xzf /tmp/patet-release.tgz -C '$RemotePath' && rm -f /tmp/patet-release.tgz"
        if ($LASTEXITCODE -ne 0) { throw "remote extract failed" }
    }
    finally {
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $archive) { Remove-Item $archive -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-UploadRelease {
    param(
        [string] $LocalPath,
        [string] $RemotePath,
        [string] $SshTarget
    )
    Write-Step "Upload $LocalPath -> $RemotePath"
    $usedRsync = Invoke-RsyncRelease -LocalPath $LocalPath -RemotePath $RemotePath -SshTarget $SshTarget
    if (-not $usedRsync) {
        Invoke-ScpTarRelease -LocalPath $LocalPath -RemotePath $RemotePath -SshTarget $SshTarget
    }
}

function Invoke-Ssh {
    param([string] $RemoteCommand)
    $extra = $env:PATET_SSH_EXTRA_ARGS
    $sshArgs = @()
    if ($extra) {
        $sshArgs += ($extra -split '\s+')
    }
    $sshArgs += "${env:PATET_SSH_USER}@${env:PATET_SSH_HOST}", $RemoteCommand
    Write-Host "ssh $($sshArgs -join ' ')"
    & ssh @sshArgs
    if ($LASTEXITCODE -ne 0) { throw "ssh failed with exit code $LASTEXITCODE" }
}

function Sync-DeploymentScriptsToServer {
    param([string] $SshTarget)
    $dest = $env:PATET_DEPLOYMENT_ROOT
    if (-not $dest) { $dest = '/var/www/patet-deployment' }
    $files = @(
        'deploy-config.sh',
        'deploy-common.sh',
        'finalize-release.sh',
        'ecosystem.config.js'
    )
    foreach ($f in $files) {
        $local = Join-Path $DeploymentDir $f
        if (-not (Test-Path $local)) { continue }
        Write-Host "Uploading deployment script $f"
        & scp $local "${SshTarget}:${dest}/$f"
        if ($LASTEXITCODE -ne 0) { throw "scp $f failed" }
    }
    Invoke-Ssh "chmod +x '$dest/finalize-release.sh' 2>/dev/null || true"
}

# --- main ---

Import-DeployLocalEnv -Path (Join-Path $DeploymentDir 'deploy.local.env')

if (-not $env:PATET_SSH_HOST -or -not $env:PATET_SSH_USER) {
    throw 'PATET_SSH_HOST and PATET_SSH_USER must be set in deploy.local.env'
}

$apiRoot = if ($env:PATET_API_ROOT) { $env:PATET_API_ROOT } else { '/var/www/patet-api' }
$webRoot = if ($env:PATET_WEB_ROOT) { $env:PATET_WEB_ROOT } else { '/var/www/patet-website' }
$deployRoot = if ($env:PATET_DEPLOYMENT_ROOT) { $env:PATET_DEPLOYMENT_ROOT } else { '/var/www/patet-deployment' }

$backendLocal = Resolve-RepoPath ($(if ($env:PATET_LOCAL_BACKEND) { $env:PATET_LOCAL_BACKEND } else { 'patet-back-nestjs' }))
$frontendLocal = Resolve-RepoPath ($(if ($env:PATET_LOCAL_FRONTEND) { $env:PATET_LOCAL_FRONTEND } else { 'patet-website' }))

$release = Get-ReleaseTimestamp
$sshTarget = "$($env:PATET_SSH_USER)@$($env:PATET_SSH_HOST)"

Write-Step "Patet Windows deploy - target=$Target release=$release"

$doBackend = $Target -eq 'backend' -or $Target -eq 'all'
$doFrontend = $Target -eq 'frontend' -or $Target -eq 'all'

if (-not $SkipBuild) {
    if ($doBackend) { Invoke-YarnBuild -RepoPath $backendLocal -Kind backend }
    if ($doFrontend) { Invoke-YarnBuild -RepoPath $frontendLocal -Kind frontend }
}

if ($SkipUpload) {
    Write-Host "SkipUpload set - done after build."
    exit 0
}

Assert-Command ssh
Assert-Command scp

if ($SyncDeploymentScripts) {
    Sync-DeploymentScriptsToServer -SshTarget $sshTarget
}

if ($doBackend) {
    $remoteBackend = "$apiRoot/releases/$release"
    Invoke-UploadRelease -LocalPath $backendLocal -RemotePath $remoteBackend -SshTarget $sshTarget
}

if ($doFrontend) {
    $remoteFrontend = "$webRoot/releases/$release"
    Invoke-UploadRelease -LocalPath $frontendLocal -RemotePath $remoteFrontend -SshTarget $sshTarget
}

$finalizeArgs = @($Target, $release)
if ($SkipMigrate) { $finalizeArgs += '--skip-migrate' }

$finalizeCmd = "cd '$deployRoot' && bash ./finalize-release.sh $($finalizeArgs -join ' ')"
Write-Step "Finalizing on server"
Invoke-Ssh -RemoteCommand $finalizeCmd

Write-Step "Deploy finished"
Write-Host "Release id: $release"
Write-Host "Check status on server: ssh $sshTarget `"cd $deployRoot && ./deploy.sh status all`""
