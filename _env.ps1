# Node/pnpm environment for the helm-d fork.
#
# Upstream pins Node 22.19.0 in .nvmrc, but nvm on this machine cannot install
# it (its metadata cache under the scoop persist dir refuses writes, and the
# nodejs.org manifest fetch times out from nvm's 3s budget). The official zip is
# unpacked to %TEMP% instead, and two .cmd shims forward `node` / `pnpm` to it.
#
# The shims matter: pnpm lifecycle children resolve `node` from PATH, so an
# ambient nvm shim (node 24) would win and .nvmrc would fail the build with
# "Node.js v22.19.0 is not installed or cannot be found".
#
# Dot-source from pwsh:   . .\_env.ps1

$NodeRoot = "C:\Users\ncui\AppData\Local\Temp\node2219\node-v22.19.0-win-x64"
$ShimDir  = "C:\Users\ncui\AppData\Local\Temp\helmd-shim"
$PnpmMjs  = "C:\Users\ncui\AppData\Local\node\corepack\v1\pnpm\11.7.0\dist\pnpm.mjs"

if (-not (Test-Path "$NodeRoot\node.exe")) { throw "node 22.19 runtime missing at $NodeRoot" }
if (-not (Test-Path $PnpmMjs))             { throw "pnpm 11.7.0 mjs missing at $PnpmMjs" }

# (Re)create the shims — cheap, and keeps them pointing at the right runtime
# after a temp cleanup.
New-Item -ItemType Directory -Force $ShimDir | Out-Null
Set-Content -Path "$ShimDir\node.cmd" -Encoding ascii -NoNewline -Value @"
@echo off
"$NodeRoot\node.exe" %*
"@
Set-Content -Path "$ShimDir\pnpm.cmd" -Encoding ascii -NoNewline -Value @"
@echo off
"$NodeRoot\node.exe" "$PnpmMjs" %*
"@

$env:PATH = "$ShimDir;$NodeRoot;$env:PATH"
$env:CI = "true"                                    # no TTY: allow pnpm to purge node_modules
$env:PNPM_HOME = "C:\Users\ncui\AppData\Local\pnpm"

Write-Host "node $(node --version)  pnpm $(pnpm --version)  (shim: $ShimDir)"
