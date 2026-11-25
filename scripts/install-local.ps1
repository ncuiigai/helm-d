# Pack this fork and install it into a DSH profile.
#
#   .\scripts\install-local.ps1                     # pack + install into profile "desktop"
#   .\scripts\install-local.ps1 -Profile web        # another profile
#   .\scripts\install-local.ps1 -PackOnly           # just produce the tgz and print its path
#   .\scripts\install-local.ps1 -NoBuild            # reuse the last tgz in dist-tgz/
#
# Why not `npm pack` from a clean clone: the package ships SEALED artifacts
# (payload.dat / references.dat / profiles.dat). They must be regenerated from
# this fork's sources before packing, or the installed plugin runs upstream's
# personas with the fork's profiles/*.md sitting unused on disk.
#
# Install path: `dsh plugin add <tgz>` copies the tarball into the profile's
# node_modules. Because the tarball is self-contained, an upstream release can't
# silently overwrite it — only an explicit `dsh plugin add` of another tarball can.

param(
    [string]$Profile = "desktop",
    [switch]$PackOnly,
    [switch]$NoBuild,
    [switch]$SkipChecks
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

    # Back up the tarball currently installed in the profile, so a bad build can
    # be rolled back without re-downloading upstream's release.
    $installedPkg = Join-Path $profileDir "node_modules\@adwmc\helm-d\package.json"
    if (Test-Path $installedPkg) {
        $oldVersion = (Get-Content $installedPkg -Raw | ConvertFrom-Json).version
        $backupDir = Join-Path $repo ".backup"
        New-Item -ItemType Directory -Force $backupDir | Out-Null
        $backupTgz = Join-Path $backupDir "helmd-$oldVersion-$(Get-Date -Format 'yyyyMMdd-HHmmss').tgz"
        Push-Location (Join-Path $profileDir "node_modules\@adwmc\helm-d")
        try {
            cmd /c "npm pack --pack-destination `"$backupDir`" 2>&1" | Out-Null
            $made = Get-ChildItem $backupDir -Filter "adwmc-helm-d-*.tgz" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($made) { Move-Item $made.FullName $backupTgz -Force }
        }
        finally { Pop-Location }
        if (Test-Path $backupTgz) { Write-Output "previous install backed up: $backupTgz" }
    }

    Write-Output "installing into profile '$Profile'..."
    if (Get-Command dsh -ErrorAction SilentlyContinue) {
        & dsh plugin --profile $Profile add $tgz.FullName
    }
    else {
        & npx --yes @deepseek-ai/dsh plugin --profile $Profile add $tgz.FullName
    }
    if ($LASTEXITCODE -ne 0) { throw "dsh plugin add failed (exit $LASTEXITCODE)" }

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
