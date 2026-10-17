import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { planImpact } from "./plan.mjs";

const packages = [
  { name: "core", dir: "crates/core", dependencies: [] },
  { name: "cli", dir: "crates/cli", dependencies: ["core"] },
  { name: "leaf", dir: "crates/leaf", dependencies: [] },
];

test("selects changed packages and transitive reverse dependencies", () => {
  assert.deepEqual(
    planImpact({ eventName: "pull_request", changedFiles: ["crates/core/src/lib.rs"], packages }),
    {
      mode: "partial",
      packages: ["cli", "core"],
      reason: "changed packages and transitive reverse dependencies: cli, core",
    },
  );
});

test("keeps complete coverage for non-PR events and global inputs", () => {
  assert.equal(planImpact({ eventName: "merge_group", changedFiles: [], packages }).mode, "full");
  assert.equal(
    planImpact({
      eventName: "pull_request",
      changedFiles: ["Cargo.lock"],
      packages,
      globalPaths: ["Cargo.lock"],
    }).mode,
    "full",
  );
});

test("selects nothing when the workspace is untouched", () => {
  assert.deepEqual(
    planImpact({ eventName: "pull_request", changedFiles: ["docs/readme.md"], packages }),
    { mode: "empty", packages: [], reason: "no Cargo workspace package changed" },
  );
});

test("maps non-Cargo inputs to their owning package before expanding dependents", () => {
  assert.equal(
    planImpact({
      eventName: "pull_request",
      changedFiles: ["docs/openapi/service.json"],
      packages,
      extraPackagePaths: [{ package: "core", prefix: "docs/openapi" }],
    }).mode,
    "partial",
  );
});

function runEntryPoint(t, { path, workflowPaths, globalPaths = "", eventName = "pull_request", pruneMergeGroup = "" }) {
  const root = mkdtempSync(join(tmpdir(), "rust-impact-entry-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  function write(path, content) {
    const target = join(root, path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, content);
  }
  write("Cargo.toml", '[workspace]\nmembers = ["crates/core", "crates/cli", "crates/leaf"]\nresolver = "2"\n');
  write("Cargo.lock", 'version = 4\n\n[[package]]\nname = "cli"\nversion = "0.1.0"\ndependencies = ["core"]\n\n[[package]]\nname = "core"\nversion = "0.1.0"\n');
  write("crates/core/Cargo.toml", '[package]\nname = "core"\nversion = "0.1.0"\nedition = "2021"\n');
  write("crates/leaf/Cargo.toml", '[package]\nname = "leaf"\nversion = "0.1.0"\nedition = "2021"\n');
  write("crates/leaf/src/lib.rs", "pub fn value() -> u8 { 2 }\n");
  write("crates/cli/Cargo.toml", '[package]\nname = "cli"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\ncore = { path = "../core" }\n');
  write("crates/core/src/lib.rs", "pub fn value() -> u8 { 1 }\n");
  write("crates/cli/src/lib.rs", "pub fn value() -> u8 { core::value() }\n");
  writeFileSync(join(root, "Cargo.lock"), readFileSync(join(root, "Cargo.lock"), "utf8") + '\n[[package]]\nname = "leaf"\nversion = "0.1.0"\n');
  const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" });
  git("init", "--quiet");
  const commit = () => {
    git("add", "--all");
    // Synthetic history must not require signing keys or run workstation hooks.
    git("-c", `core.hooksPath=${join(root, "empty-hooks")}`, "-c", "commit.gpgsign=false",
      "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Fixture");
  };
  commit();
  const base = git("rev-parse", "HEAD").trim();
  const previous = path === "Cargo.lock" ? readFileSync(join(root, path), "utf8") : "";
  write(path, previous + (path.endsWith(".rs") ? "\n// changed fixture\n" : "\n# changed fixture\n"));
  commit();
  const output = join(root, "github-output");
  const env = {
    ...process.env,
    GITHUB_OUTPUT: output,
    RUST_IMPACT_EVENT_NAME: eventName,
    RUST_IMPACT_BASE: base,
    RUST_IMPACT_HEAD: "HEAD",
    RUST_IMPACT_WORKSPACE: ".",
    RUST_IMPACT_GLOBAL_PATHS: globalPaths,
    RUST_IMPACT_EXTRA_PACKAGE_PATHS: "",
    RUST_IMPACT_PRUNE_MERGE_GROUP: pruneMergeGroup,
  };
  if (workflowPaths === undefined) delete env.RUST_IMPACT_WORKFLOW_PATHS;
  else env.RUST_IMPACT_WORKFLOW_PATHS = workflowPaths;
  execFileSync(process.execPath, [fileURLToPath(new URL("./plan.mjs", import.meta.url))], {
    cwd: root, env, encoding: "utf8",
  });
  return Object.fromEntries(readFileSync(output, "utf8").trim().split("\n").map((line) => {
    const separator = line.indexOf("=");
    return [line.slice(0, separator), line.slice(separator + 1)];
  }));
}

test("entry point honors workflow scope without weakening Cargo coverage", async (t) => {
  const cases = [
    { name: "unrelated workflow", path: ".github/workflows/docs.yml", workflowPaths: ".github/workflows/rust.yml", mode: "empty" },
    { name: "non-workflow negative control", path: "docs/readme.md", workflowPaths: ".github/workflows/rust.yml", mode: "empty" },
    { name: "declared workflow", path: ".github/workflows/ci.yml", workflowPaths: ".github/workflows/rust.yml\n.github/workflows/ci.yml", mode: "full" },
    { name: "conservative default", path: ".github/workflows/docs.yml", mode: "full" },
    { name: "explicit empty workflow list", path: ".github/workflows/docs.yml", workflowPaths: "", mode: "empty" },
    { name: "Cargo lock remains global", path: "Cargo.lock", workflowPaths: ".github/workflows/rust.yml", mode: "full" },
    { name: "additional caller global", path: "docs/ci-policy.json", workflowPaths: ".github/workflows/rust.yml", globalPaths: "docs/ci-policy.json", mode: "full" },
    { name: "actual reverse dependency graph", path: "crates/core/src/lib.rs", workflowPaths: ".github/workflows/rust.yml", mode: "partial" },
    { name: "merge groups remain full", path: ".github/workflows/docs.yml", workflowPaths: ".github/workflows/rust.yml", eventName: "merge_group", mode: "full" },
    { name: "opted-in merge group selects its own entry", path: ".github/workflows/docs.yml", workflowPaths: ".github/workflows/rust.yml", eventName: "merge_group", pruneMergeGroup: "true", mode: "empty" },
    { name: "opted-in merge group still reaches changed Rust", path: "crates/core/src/lib.rs", workflowPaths: ".github/workflows/rust.yml", eventName: "merge_group", pruneMergeGroup: "true", mode: "partial" },
    { name: "push ignores the merge-group opt-in", path: "docs/readme.md", workflowPaths: ".github/workflows/rust.yml", eventName: "push", pruneMergeGroup: "true", mode: "full" },
  ];
  for (const scenario of cases) {
    await t.test(scenario.name, (t) => {
      const result = runEntryPoint(t, scenario);
      assert.equal(result.mode, scenario.mode);
      assert.deepEqual(JSON.parse(result.packages), scenario.mode === "empty" ? [] : scenario.mode === "full" ? ["cli", "core", "leaf"] : ["cli", "core"]);
      assert.equal(result["package-args"], scenario.mode === "full" ? "--workspace" : scenario.mode === "partial" ? "-p cli -p core" : "");
      assert.doesNotMatch(result.reason, /could not be resolved/);
    });
  }
});

test("action projects the workflow input and its conservative default", () => {
  const action = readFileSync(new URL("./action.yml", import.meta.url), "utf8");
  assert.match(action, /workflow-paths:[\s\S]*?default: "\.github\/workflows"/);
  assert.ok(action.includes("RUST_IMPACT_WORKFLOW_PATHS: ${{ inputs.workflow-paths }}"));
  assert.match(action, /prune-merge-group:[\s\S]*?default: "false"/);
  assert.ok(action.includes("RUST_IMPACT_PRUNE_MERGE_GROUP: ${{ inputs.prune-merge-group }}"));
});
