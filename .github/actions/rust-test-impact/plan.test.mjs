import assert from "node:assert/strict";
import test from "node:test";

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
