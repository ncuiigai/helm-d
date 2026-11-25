# Answer two different questions that GitHub's UI blends into one banner.
#
#   .\scripts\check-upstream.ps1
#
# GitHub says "fiction-mode 分支有了最新的推送" when YOUR branch moved, not when
# upstream moved. Those are different events with different consequences:
#
#   branch pushed   -> your own commits landed on origin; nothing to sync
#   upstream moved  -> upstream/main advanced past your base; rebase + rebuild
#
# This script prints both, separately, with the numbers that decide it.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $repo
try {
    git fetch upstream --tags --prune --quiet
    git fetch origin --quiet

    $branch = git rev-parse --abbrev-ref HEAD
    $upHead = git rev-parse upstream/main
    $upShort = $upHead.Substring(0, 8)
    $upDate = git log -1 --format=%cI upstream/main
    $upSubject = git log -1 --format=%s upstream/main

    $behind = [int](git rev-list --count "HEAD..upstream/main")
    $ahead = [int](git rev-list --count "upstream/main..HEAD")

    # What the fork's own remote tip is — this is what GitHub's banner reacts to.
    $originTip = git ls-remote origin "refs/heads/$branch" 2>$null | ForEach-Object { ($_ -split "\s+")[0] }
    $localTip = git rev-parse HEAD

    Write-Output "repo:     $repo"
    Write-Output "branch:   $branch  @ $($localTip.Substring(0,8))"
    Write-Output ""
    Write-Output "upstream/main  $upShort  $upDate"
    Write-Output "               $upSubject"
    Write-Output ""

    if ($behind -eq 0) {
        Write-Output "UPSTREAM: no update  (behind 0)"
        Write-Output "  Nothing to rebase. A 'branch was pushed' banner on GitHub refers to"
        Write-Output "  your own push, not to upstream — check the commit hash in the banner."
    }
    else {
        Write-Output "UPSTREAM: $behind new commit(s)  -- sync needed"
        git log --oneline "HEAD..upstream/main" | Select-Object -First 20
        Write-Output ""
        Write-Output "  run:  .\scripts\sync-upstream.ps1"
    }

    Write-Output ""
    Write-Output "fork:      ahead $ahead of upstream/main"
    if ($originTip) {
        $same = $originTip -eq $localTip
        Write-Output "origin/$branch  $($originTip.Substring(0,8))  $(if ($same) { '(matches local)' } else { '(DIFFERS - push needed)' })"
    }
    else {
        Write-Output "origin/$branch  (not pushed yet)"
    }

    # Sealed artifacts are build output in this fork; a stale one means the
    # installed package does not match the sources.
    $sealed = @(
        "packages/helmd/payload.dat",
        "packages/helmd/references.dat",
        "packages/helmd/presets/profiles.dat"
    )
    Write-Output ""
    Write-Output "sealed artifacts (build output, gitignored):"
    foreach ($f in $sealed) {
        $p = Join-Path $repo $f
        if (Test-Path $p) {
            $age = (Get-Date) - (Get-Item $p).LastWriteTime
            Write-Output ("  {0,-42} {1,8} bytes  {2:N0} min old" -f $f, (Get-Item $p).Length, $age.TotalMinutes)
        }
        else {
            Write-Output ("  {0,-42} MISSING - run .\scripts\install-local.ps1" -f $f)
        }
    }
}
finally {
    Pop-Location
}
