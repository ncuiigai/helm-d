# Sync this fork with upstream and rebuild the fork-local persona catalog.
#
#   .\scripts\sync-upstream.ps1                 # fetch, rebase fiction-mode onto upstream/main, rebuild
#   .\scripts\sync-upstream.ps1 -DryRun         # show what a merge would bring, change nothing
#   .\scripts\sync-upstream.ps1 -Tag v0.7.0     # rebase onto a specific upstream tag instead of main
#   .\scripts\sync-upstream.ps1 -SkipChecks     # rebuild only (fast loop while iterating)
#
# Why a script: the three sealed artifacts are committed upstream AND regenerated
# here, so a naive merge leaves conflict markers inside AES blobs. .gitattributes
# marks them `merge=ours`; this script additionally re-runs the generators after
# every merge, so the committed blobs always match the fork's own sources.
#
# Exit codes: 0 = clean, 1 = conflict or gate failure (nothing is force-pushed).

param(
    [string]$Tag,
    [switch]$DryRun,
    [switch]$SkipChecks
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $repo
try {
    . (Join-Path $repo "_env.ps1") | Out-Null

    $branch = git rev-parse --abbrev-ref HEAD
    if ($branch -eq "HEAD") { throw "detached HEAD — check out a branch first" }

    Write-Output "fetch upstream..."
    git fetch upstream --tags --prune
    if ($LASTEXITCODE -ne 0) { throw "git fetch upstream failed" }

    $target = if ($Tag) { "refs/tags/$Tag" } else { "upstream/main" }
    git rev-parse --verify $target | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "target $target not found" }

    $behind = git rev-list --count "HEAD..$target"
    $ahead = git rev-list --count "$target..HEAD"
    Write-Output "branch '$branch': ahead $ahead, behind $behind ($target)"

    if ($DryRun) {
        Write-Output ""
        Write-Output "incoming commits:"
        git log --oneline "HEAD..$target" | Select-Object -First 40
        Write-Output ""
        Write-Output "files that would change:"
        git diff --stat "HEAD..$target" | Select-Object -Last 25
        Write-Output ""
        Write-Output "[dry run — nothing changed]"
        exit 0
    }

    # Refuse to merge on a dirty tree: the sealed blobs regenerate below, and a
    # half-applied merge would be indistinguishable from a local edit.
    if ((git status --porcelain | Measure-Object).Count -gt 0) {
        throw "working tree is dirty — commit or stash first (git status)"
    }

    if ($behind -gt 0) {
        Write-Output "rebasing onto $target..."
        git rebase $target
        if ($LASTEXITCODE -ne 0) {
            Write-Output ""
            Write-Output "REBASE CONFLICT. Resolve, then:"
            Write-Output "  git add -A ; git rebase --continue ; .\scripts\sync-upstream.ps1 -SkipChecks"
            Write-Output "To bail out:  git rebase --abort"
            throw "rebase stopped with conflicts (exit $LASTEXITCODE)"
        }
    }
    else {
        Write-Output "already up to date with $target"
    }

    # Regenerate every fork-owned generated artifact from the fork's sources.
    # This is what makes `merge=ours` safe: the committed blob is derivable.
    Write-Output ""
    Write-Output "rebuilding sealed artifacts..."
    pnpm build 2>&1 | Select-Object -Last 2
    if ($LASTEXITCODE -ne 0) { throw "pnpm build failed" }
    node (Join-Path $repo "packages\helmd\scripts\build-profiles.mjs")
    if ($LASTEXITCODE -ne 0) { throw "build-profiles failed" }

    if (-not $SkipChecks) {
        Write-Output ""
        Write-Output "running the completion gate..."
        pnpm typecheck 2>&1 | Select-Object -Last 2
        if ($LASTEXITCODE -ne 0) { throw "pnpm typecheck failed" }
        node (Join-Path $repo "scripts\checks\run-all.mjs") 2>&1 | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { throw "check suite failed" }
    }

    $changed = git status --porcelain
    if ($changed) {
        Write-Output ""
        Write-Output "regenerated artifacts changed; commit them:"
        $changed | Select-Object -First 20
        $stamp = Get-Date -Format "yyyy-MM-dd"
        Write-Output ""
        Write-Output "  git add -A ; git commit -m `"chore: regenerate sealed catalog after upstream sync ($stamp)`""
    }
    else {
        Write-Output ""
        Write-Output "regenerated artifacts are already current"
    }

    Write-Output ""
    Write-Output "install into the running profile:"
    Write-Output "  .\scripts\install-local.ps1"
}
finally {
    Pop-Location
}
