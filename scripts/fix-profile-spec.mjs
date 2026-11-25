// Point a DSH profile at a helm-d tarball, surgically.
//
//   node scripts/fix-profile-spec.mjs <profileDir> <spec>
//   node scripts/fix-profile-spec.mjs C:/Users/me/.dsh/profiles/desktop \
//        file:C:/Users/me/.dsh/.tgz-cache/helm-d-v0.7.1.tgz
//
// Why this exists: switching a profile's helm-d specifier between shapes
// (`file:<path>` <-> `https://…releases/download/…`) leaves pnpm's lockfile
// entry without an `integrity` field, and pnpm then refuses to install:
//
//   ERR_PNPM_MISSING_TARBALL_INTEGRITY: ... its lockfile entry has no
//   "integrity" field, so pnpm cannot verify the downloaded tarball.
//
// `pnpm add`, `pnpm install --update-checksums`, and hand-patching the digest
// all fail to clear it (the tag is keyed by specifier + peer tuple, so a
// partially rewritten lockfile keeps re-deriving an entry with no digest).
// What does work: rewrite the manifest, drop the helm-d package/snapshot
// blocks from the lockfile, and let `pnpm install` re-resolve that ONE
// dependency — no node_modules purge, no re-resolve of the other 134 packages.
//
// Install source note: point the specifier at a local copy of the release
// asset (file:…) rather than the release URL. A `file:` spec installs from
// bytes that cannot change under you, which is the same guarantee a versioned
// URL gives, without pnpm's remote-integrity bookkeeping.
import { readFileSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
import { join } from "node:path";

const [profileDir, spec] = process.argv.slice(2);
if (!profileDir || !spec) throw new Error("usage: node scripts/fix-profile-spec.mjs <profileDir> <spec>");

const pkgPath = join(profileDir, "package.json");
const lockPath = join(profileDir, "pnpm-lock.yaml");
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
copyFileSync(pkgPath, `${pkgPath}.${stamp}.bak`);
if (existsSync(lockPath)) copyFileSync(lockPath, `${lockPath}.${stamp}.bak`);

// ── manifest ────────────────────────────────────────────────────────────────
const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
pkg.dependencies ??= {};
const previous = pkg.dependencies["@adwmc/helm-d"];
pkg.dependencies["@adwmc/helm-d"] = spec;
writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n", "utf8");
console.log(`manifest: @adwmc/helm-d = ${spec}`);
if (previous && previous !== spec) console.log(`  was: ${previous}`);

// ── lockfile ────────────────────────────────────────────────────────────────
if (!existsSync(lockPath)) {
  console.log("lockfile: absent — pnpm will resolve from scratch");
  process.exit(0);
}

let lock = readFileSync(lockPath, "utf8");
const before = lock;

// 1. The importer block under `importers: .: dependencies:`.
//    Replaced as a WHOLE block (header + every 8-space-indented child), not as
//    a two-line pattern: an already-damaged lockfile may be missing the
//    `version:` line, and a pattern that requires both lines then silently
//    matches nothing while still reporting success.
lock = lock.replace(
  /^ {6}'@adwmc\/helm-d':\r?\n(?: {8}.*\r?\n)*/m,
  `      '@adwmc/helm-d':\n        specifier: ${spec}\n        version: ${spec}\n`,
);

// 2. Every `'@adwmc/helm-d@<old>':` entry in the `packages:` and `snapshots:`
//    sections. Dropping them is what forces a re-resolve with a fresh digest.
//    Done line-by-line because an entry has two shapes:
//      '@adwmc/helm-d@file:x.tgz': {}          (empty, one line)
//      '@adwmc/helm-d@file:x.tgz':             (nested keys, indented 4)
//        resolution: {...}
//    A single regex miss strands the old key, and pnpm then re-derives the entry
//    from it — the peer-tuple variant (`…tgz(@deepseek-ai/schemastery@3.20.0)`)
//    still has no integrity, so the install fails again.
const outLines = [];
let dropping = false;
let dropped = 0;
for (const line of lock.split("\n")) {
  const isEntry = /^ {2}'@adwmc\/helm-d@[^']*':/.test(line);
  if (isEntry) {
    dropping = true;
    dropped += 1;
    continue; // skip the header itself
  }
  if (dropping) {
    // Continuation: indented 4+ spaces (nested keys). Anything else ends it.
    if (/^ {4,}\S/.test(line)) continue;
    dropping = false;
  }
  outLines.push(line);
}
lock = outLines.join("\n");

// 3. collapse blank line runs left behind, so the YAML stays readable.
lock = lock.replace(/\n{3,}/g, "\n\n");

if (lock === before) {
  console.log("lockfile: no helm-d entries found to rewrite");
} else {
  writeFileSync(lockPath, lock, "utf8");
  console.log(`lockfile: importer rewritten, ${dropped} package/snapshot block(s) dropped`);
}

// Sanity: the manifest specifier and the lockfile importer must agree, else
// pnpm treats the lockfile as stale and refuses.
const check = readFileSync(lockPath, "utf8");
if (!check.includes(`specifier: ${spec}`)) {
  throw new Error("lockfile importer does not carry the new specifier");
}
console.log("verdict: profile now targets the new specifier; run pnpm install");
