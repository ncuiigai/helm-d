// Proof that a packed tarball carries THIS fork's catalog.
//
//   node scripts/check-tarball.mjs <tarball> [expectedActiveId]
//   node scripts/check-tarball.mjs dist-tgz/helm-d.tgz            # default: fiction
//
// Run by .github/workflows/release.yml before the asset is uploaded, and usable
// locally before pushing a tag. The tarball is the only thing a user ever
// installs, so its own sealed catalog is what must be inspected — checking the
// repo sources proves nothing about what npm pack actually picked up (the
// `files` whitelist is what decides that).
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createDecipheriv, scryptSync } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const tgz = process.argv[2];
const expectedActive = process.argv[3] ?? "fiction";
if (!tgz) throw new Error("usage: node scripts/check-tarball.mjs <tarball> [expectedActiveId]");
if (!existsSync(tgz)) throw new Error(`tarball not found: ${tgz}`);

// Same key as packages/helmd/src/crypt.ts. The seal is a static-scanner speed
// bump, not a secret — upstream's own ruling, kept here so the check can read
// what it just built.
const KEY = scryptSync(
  "helm-d/profiles/v1::6f4d2a0c-9e17-4b8e-a3f2-c81d54e7b930",
  "helm-d/profiles/v1::salt-v1",
  32,
);
function unseal(s) {
  const [i, t, d] = s.split(".");
  const c = createDecipheriv("aes-256-gcm", KEY, Buffer.from(i, "base64url"));
  c.setAuthTag(Buffer.from(t, "base64url"));
  return Buffer.concat([c.update(Buffer.from(d, "base64url")), c.final()]).toString("utf8");
}

/** Profiles this fork must ship, and the id the host loads by default. */
const REQUIRED_PROFILES = ["fiction", "fiction-t5", "fiction-t2"];
/** Sealed runtime modules the persona contract depends on. */
const REQUIRED_MODULES = [
  ".real/gate.js",
  ".real/profile.js",
  ".real/catalog.js",
  ".real/crypt.js",
  ".real/llm-stream-hook.js",
];

const tmp = mkdtempSync(join(tmpdir(), "helmd-tgz-"));
try {
  execFileSync("tar", ["-xzf", resolve(tgz), "-C", tmp], { stdio: "inherit" });
  const root = join(tmp, "package");

  const pkgJson = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  console.log(`package: ${pkgJson.name}@${pkgJson.version}`);

  const dat = JSON.parse(readFileSync(join(root, "presets", "profiles.dat"), "utf8"));
  console.log(`catalog: activeId=${dat.activeId}  profiles=${dat.profiles.length}`);
  const ids = [];
  for (const p of dat.profiles) {
    const body = unseal(p.sealed);
    if (!body.trim()) throw new Error(`empty body: ${p.id}`);
    ids.push(p.id);
    console.log(`  ${p.id.padEnd(12)} ${String(body.length).padStart(6)}c  ${p.name ?? ""}`);
  }

  const manifest = JSON.parse(unseal(readFileSync(join(root, "payload.dat"), "utf8")));
  const sealed = Object.keys(manifest.files ?? {});
  console.log(`payload: ${sealed.length} sealed files`);
  for (const need of REQUIRED_MODULES) {
    if (!sealed.includes(need)) throw new Error(`payload missing ${need}`);
  }
  if (!existsSync(join(root, "references.dat"))) throw new Error("references.dat missing");

  // A plaintext persona would mean the seal step was skipped.
  if (pkgJson.files?.includes("presets/persona.txt") === true) {
    throw new Error("package.json files whitelist ships presets/persona.txt (plaintext persona)");
  }

  if (dat.activeId !== expectedActive) {
    throw new Error(`activeId is "${dat.activeId}", expected "${expectedActive}"`);
  }
  if (!dat.boost) throw new Error("boost tail block missing");
  for (const need of REQUIRED_PROFILES) {
    if (!ids.includes(need)) throw new Error(`tarball is missing profile ${need}`);
  }

  console.log("\nverdict: packed tarball carries this fork's catalog");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
