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
    $previousSpec = (Get-Content $manifestPath -Raw | ConvertFrom-Json).dependencies.'@adwmc/helm-d'
    $spec = if ($UseReleaseUrl) {
        $v = (Get-Content (Join-Path $repo "packages\helmd\package.json") -Raw | ConvertFrom-Json).version
        "https://github.com/ncuiigai/helm-d/releases/download/v$v/helm-d.tgz"
    }
    else {
        "file:" + ($tgz.FullName -replace '\\', '/')
    }

    # The manifest/lockfile rewrite is delegated: switching specifier SHAPES
    # leaves pnpm's lockfile entry without an integrity field, and pnpm then
    # refuses (ERR_PNPM_MISSING_TARBALL_INTEGRITY). fix-profile-spec.mjs drops
    # just the helm-d lockfile blocks so `pnpm install` re-resolves that one
    # dependency instead of the whole profile.
    & node (Join-Path $repo "scripts\fix-profile-spec.mjs") $profileDir $spec
    if ($LASTEXITCODE -ne 0) { throw "fix-profile-spec failed (exit $LASTEXITCODE)" }
    Write-Output "profile '$Profile' dependency: $spec"
    if ($previousSpec -and $previousSpec -ne $spec) { Write-Output "  (was: $previousSpec)" }

    Write-Output "installing (pnpm install)..."
    Push-Location $profileDir
    try {
        # Capture the exit code before any pipeline runs: `pnpm ... | Select-Object`
        # leaves $LASTEXITCODE pointing at pnpm, but keeping the raw output lets a
        # failure print the actual reason instead of a bare exit code.
        $installOut = pnpm install 2>&1
        $installCode = $LASTEXITCODE

        # Switching specifier SHAPES (file: <-> https URL) drops the lockfile
        # entry's `integrity` field, and pnpm then refuses to install:
        #   ERR_PNPM_MISSING_TARBALL_INTEGRITY ... cannot verify the downloaded tarball
        # The fix is to recompute the digest of the exact tarball and write it back
        # rather than regenerating the whole lockfile (which would re-resolve every
        # other dependency in the profile).
        if ($installCode -ne 0 -and ($installOut -join "`n") -match 'MISSING_TARBALL_INTEGRITY') {
            Write-Output "  lockfile lost the integrity field for the new specifier; recomputing..."
            $lockPath = Join-Path $profileDir "pnpm-lock.yaml"

            # Hash the artifact the SPECIFIER names, not "some tarball we have".
            # The sealed blobs use a random IV, so a local rebuild and the release
            # asset built from the same sources are different bytes — hashing the
            # wrong one produces a lockfile that fails with ERR_PNPM_TARBALL_INTEGRITY
            # ("Wanted sha512-RhPd… Got sha512-CQ4O…").
            if ($spec -match '^https?://') {
                $hashSrc = Join-Path $env:TEMP ("helmd-integrity-" + [guid]::NewGuid().ToString('N') + ".tgz")
                Write-Output "  downloading the release asset to hash it..."
                Invoke-WebRequest -Uri $spec -OutFile $hashSrc -UseBasicParsing
            }
            else {
                $hashSrc = $tgz.FullName
            }
            try {
                $bytes = [System.IO.File]::ReadAllBytes($hashSrc)
                $sha512 = [System.Security.Cryptography.SHA512]::Create().ComputeHash($bytes)
                $digest = "sha512-" + [Convert]::ToBase64String($sha512)
            }
            finally {
                if ($hashSrc -ne $tgz.FullName) { Remove-Item $hashSrc -Force -ErrorAction SilentlyContinue }
            }

            $lock = Get-Content $lockPath -Raw
            $key = "@adwmc/helm-d@$spec"
            # Replace the resolution line for THIS package only, leaving every
            # other importer/package entry untouched.
            $pattern = "(?ms)^(  '" + [regex]::Escape($key) + "':\r?\n    resolution: )\{[^}]*\}"
            if ($lock -notmatch $pattern) { throw "cannot locate the lockfile resolution line for $key" }
            $lock = $lock -replace $pattern, ('$1' + '{integrity: ' + $digest + ', tarball: ' + $spec + '}')
            Set-Content -Path $lockPath -Value $lock -Encoding utf8 -NoNewline
            Write-Output "  wrote integrity $($digest.Substring(0, 20))... for $key"

            $installOut = pnpm install 2>&1
            $installCode = $LASTEXITCODE
        }

        $installOut | Select-Object -Last 4
        if ($installCode -ne 0) {
            Write-Output ""
            Write-Output "pnpm install output (last 20 lines):"
            $installOut | Select-Object -Last 20
            Copy-Item (Join-Path $backupDir "profile-$Profile-package.json.$stamp.bak") $manifestPath -Force
            Copy-Item (Join-Path $backupDir "profile-$Profile-pnpm-lock.yaml.$stamp.bak") $lockPath -Force
            throw "pnpm install failed (exit $installCode); profile manifest + lockfile restored from backup"
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
