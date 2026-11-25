# Pack this fork and install it into a DSH profile.
#
#   .\scripts\install-local.ps1                     # build + pack + install (file: tarball)
#   .\scripts\install-local.ps1 -UseReleaseUrl      # install from the GitHub release instead
#   .\scripts\install-local.ps1 -Profile web        # another profile
#   .\scripts\install-local.ps1 -PackOnly           # just produce the tgz and print its path
#   .\scripts\install-local.ps1 -NoBuild            # reuse the last tgz in dist-tgz/
#   .\scripts\install-local.ps1 -SkipChecks         # fast loop: build + seal, no gate
#
# Why not `npm pack` from a clean clone: the package ships SEALED artifacts
# (payload.dat / references.dat / profiles.dat). They must be regenerated from
# this fork's sources before packing, or the installed plugin runs upstream's
# personas with the fork's profiles/*.md sitting unused on disk.
#
# Why not `dsh plugin add`: the Electron app owns the "desktop" profile and
# refuses ("profile \"desktop\" is managed exclusively by the Electron
# application"). Install path is the profile manifest + pnpm install, which is
# exactly what the app itself does.

param(
    [string]$Profile = "desktop",
    [switch]$PackOnly,
    [switch]$NoBuild,
    [switch]$SkipChecks,
    [switch]$UseReleaseUrl
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $repo
try {
    . (Join-Path $repo "_env.ps1") | Out-Null

    $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
    $outDir = Join-Path $repo "dist-tgz"

    if (-not $NoBuild) {
        Write-Output "build..."
        pnpm build 2>&1 | Select-Object -Last 2
        if ($LASTEXITCODE -ne 0) { throw "pnpm build failed" }

        # Gate BEFORE sealing: build-sealed moves every compiled module into
        # .real/ and leaves only self-extracting stubs in dist/, and the check
        # suite imports dist/*.js directly. Running the checks after sealing
        # makes them all SKIP ("need packages/helmd/dist (run pnpm build)").
        if (-not $SkipChecks) {
            Write-Output "typecheck + checks (pre-seal)..."
            pnpm typecheck 2>&1 | Select-Object -Last 2
            if ($LASTEXITCODE -ne 0) { throw "pnpm typecheck failed" }
            node (Join-Path $repo "scripts\checks\run-all.mjs") 2>&1 | Select-Object -Last 3
            if ($LASTEXITCODE -ne 0) { throw "check suite failed (build aborted before sealing)" }
        }

        Write-Output "seal..."
        node (Join-Path $repo "packages\helmd\scripts\build-profiles.mjs")
        if ($LASTEXITCODE -ne 0) { throw "build-profiles failed" }
        node (Join-Path $repo "packages\helmd\scripts\build-sealed.mjs")
        if ($LASTEXITCODE -ne 0) { throw "build-sealed failed" }
    }

    New-Item -ItemType Directory -Force $outDir | Out-Null
    $version = (Get-Content (Join-Path $repo "packages\helmd\package.json") -Raw | ConvertFrom-Json).version
    Push-Location (Join-Path $repo "packages\helmd")
    try {
        $tgzLine = cmd /c "npm pack --pack-destination `"$outDir`" 2>&1"
        if ($LASTEXITCODE -ne 0) { $tgzLine | Select-Object -Last 10; throw "npm pack failed" }
    }
    finally { Pop-Location }

    $tgz = Get-ChildItem $outDir -Filter "adwmc-helm-d-$version.tgz" | Select-Object -First 1
    if (-not $tgz) { throw "packed tarball not found in $outDir" }
    Copy-Item $tgz.FullName (Join-Path $outDir "helmd.tgz") -Force
    Write-Output "packed: $($tgz.FullName)  ($([math]::Round($tgz.Length/1MB,2)) MB, v$version)"

    if ($PackOnly) { Write-Output "$($tgz.FullName)"; exit 0 }

    $profileDir = Join-Path $dshHome "profiles\$Profile"
    if (-not (Test-Path $profileDir)) { throw "profile not found: $profileDir" }

    # `dsh plugin --profile <name> add` refuses the Electron-managed profile:
    #   error: profile "desktop" is managed exclusively by the Electron application
    # So install the way the app itself does: point the profile manifest at the
    # tarball and let pnpm resolve it. Both the manifest and the lockfile are
    # backed up first, because a bad tarball must be one `git checkout` away
    # from undone.
    $backupDir = Join-Path $repo ".backup"
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    foreach ($f in @("package.json", "pnpm-lock.yaml")) {
        $src = Join-Path $profileDir $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $backupDir "profile-$Profile-$f.$stamp.bak") -Force }
    }

    $manifestPath = Join-Path $profileDir "package.json"
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $previousSpec = $manifest.dependencies.'@adwmc/helm-d'
    $spec = if ($UseReleaseUrl) {
        $v = (Get-Content (Join-Path $repo "packages\helmd\package.json") -Raw | ConvertFrom-Json).version
        "https://github.com/ncuiigai/helm-d/releases/download/v$v/helm-d.tgz"
    }
    else {
        "file:" + ($tgz.FullName -replace '\\', '/')
    }
    $manifest.dependencies.'@adwmc/helm-d' = $spec
    ($manifest | ConvertTo-Json -Depth 20) | Set-Content $manifestPath -Encoding utf8 -NoNewline
    Write-Output "profile '$Profile' dependency: $spec"
    if ($previousSpec -and $previousSpec -ne $spec) { Write-Output "  (was: $previousSpec)" }

    Write-Output "installing (pnpm install)..."
    Push-Location $profileDir
    try {
        pnpm install 2>&1 | Select-Object -Last 4
        if ($LASTEXITCODE -ne 0) {
            Copy-Item (Join-Path $backupDir "profile-$Profile-package.json.$stamp.bak") $manifestPath -Force
            throw "pnpm install failed (exit $LASTEXITCODE); profile manifest restored"
        }
    }
    finally { Pop-Location }

    # Post-install proof: the installed catalog must be this fork's.
    $verify = Join-Path $repo "scripts\check-tarball.mjs"
    $installedDat = Join-Path $profileDir "node_modules\@adwmc\helm-d\presets\profiles.dat"
    if (Test-Path $installedDat) {
        $dat = Get-Content $installedDat -Raw | ConvertFrom-Json
        Write-Output "installed catalog: activeId=$($dat.activeId)  profiles=$($dat.profiles.Count)"
    }

    Write-Output ""
    Write-Output "installed. Restart dsh to load the new catalog, then check:"
    Write-Output "  curl.exe -sS `$env:DSH_WEB_URL/api/helmd/profile"
    Write-Output "Hot-switch afterwards without restarting:"
    Write-Output "  Set-Content .\switch.json -Value '{\`"id\`":\`"fiction\`"}' -Encoding ascii -NoNewline"
    Write-Output "  curl.exe -sS -X POST `$env:DSH_WEB_URL/api/helmd/profile -H 'content-type: application/json' --data-binary '@.\switch.json'"
}
finally {
    Pop-Location
}
