import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const action = dirname(fileURLToPath(import.meta.url));
const steps = JSON.parse(execFileSync("ruby", ["-ryaml", "-rjson", "-e",
  "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]))['runs']['steps'])", join(action, "action.yml")], { encoding: "utf8" }));
const sha = "a".repeat(40);
const policy = {
  schema_version: 1, repository: "burin-labs/example", workflow: "ci.yml", event: "merge_group",
  topology_epoch: "2026-08-08T00:00:00Z", full_run_jobs: [{ name: "Build", match: "exact" }],
  slo: { warning_ms: 540000, p90_ms: 600000, hard_max_ms: 900000, min_samples: 5, window_samples: 5 },
  required: { aggregate_job: "status", critical_path_allowance_ms: 600000, jobs: { build: { budget_ms: 500000 } } },
};

async function fixture(callback) {
  const root = await mkdtemp(join(tmpdir(), "baseline-action-test-"));
  try {
    await writeFile(join(root, "policy.json"), JSON.stringify(policy));
    await writeFile(join(root, "workflow.yml"), "jobs:\n  build: {}\n  status:\n    needs: [build]\n");
    const preload = join(root, "transport.mjs");
    await writeFile(preload, `
      const policy = ${JSON.stringify(policy)};
      const sha = ${JSON.stringify(sha)}, tree = 'b'.repeat(40);
      let count = 0;
      globalThis.fetch = async (_url, options) => {
        if (options.headers.Authorization !== 'Bearer fixture-token') throw Error('wrong auth');
        count++;
        const mode = process.env.FIXTURE_MODE;
        if (mode === 'exhausted' || (mode === 'recover' && count === 1)) return new Response('{}', {status:503});
        if (mode === 'denied') return new Response('{}', {status:403});
        if (mode === 'partial') return new Response('{"repository":');
        if (mode === 'absent') {
          if (count === 1) return new Response('{}', {status:404});
          if (count === 2) return Response.json({sha, tree:{sha:tree}});
          if (count === 3) return Response.json({sha:tree, truncated:false, tree:[{path:'README.md',type:'blob'}]});
          throw Error('unexpected extra request');
        }
        return Response.json(policy);
      };
    `);
    const env = { ...process.env, NODE_OPTIONS: `--import=${pathToFileURL(preload).href}`,
      GITHUB_ACTION_PATH: action, GITHUB_REPOSITORY: policy.repository, BASELINE_SHA: sha,
      GH_TOKEN: "fixture-token", POLICY_PATH: "policy.json", WORKFLOW_PATH: "workflow.yml",
      RUNNER_TEMP: root, GITHUB_OUTPUT: join(root, "output"), BASELINE_STATE: "", BASELINE_FILE: "" };
    const run = (step, extra = {}) => spawnSync("bash", ["-e", "-o", "pipefail", "-c", step.run],
      { cwd: root, env: { ...env, ...extra }, encoding: "utf8", timeout: 10000 });
    await callback({ root, run, env });
  } finally { await rm(root, { recursive: true, force: true }); }
}

test("actual action recovers503, emits usable atomic baseline and reaches unchanged budget checker", async () => {
  await fixture(async ({ root, run }) => {
    const read = run(steps[0], { FIXTURE_MODE: "recover" });
    assert.equal(read.status, 0, read.stderr);
    const receipt = JSON.parse(read.stdout);
    assert.equal(receipt.attempts, 2);
    assert.equal(receipt.pendingCount, 0);
    const outputs = Object.fromEntries((await readFile(join(root, "output"), "utf8")).trim().split("\n").map(line => {
      const split = line.indexOf("="); return [line.slice(0, split), line.slice(split + 1)];
    }));
    const env = { BASELINE_STATE: outputs.state, BASELINE_FILE: outputs["baseline-path"] };
    const checked = run(steps[1], env);
    assert.equal(checked.status, 0, checked.stderr);
    assert.match(checked.stdout, /CI latency policy: OK/);
    const loosened = structuredClone(policy);
    loosened.required.jobs.build.budget_ms += 1;
    await writeFile(join(root, "policy.json"), JSON.stringify(loosened));
    const refused = run(steps[1], env);
    assert.equal(refused.status, 1);
    assert.match(refused.stderr, /budget may only decrease/);
    assert.ok(!`${read.stdout}${read.stderr}${checked.stdout}${checked.stderr}`.includes("fixture-token"));
  });
});

test("actual CLI failure leaves neither outputs nor a replacement baseline", async () => {
  for (const mode of ["exhausted", "denied", "partial"]) {
    await fixture(async ({ root, run }) => {
      const baseline = join(root, "ci-latency-baseline.json");
      await writeFile(baseline, "previous qualified baseline");
      const read = run(steps[0], { FIXTURE_MODE: mode });
      assert.equal(read.status, 1, mode);
      assert.equal(JSON.parse(read.stderr).pendingCount, 1);
      assert.deepEqual(JSON.parse(read.stderr).failingNames, ["immutable-baseline"]);
      await assert.rejects(readFile(join(root, "output")), { code: "ENOENT" });
      assert.equal(await readFile(baseline, "utf8"), "previous qualified baseline");
      assert.ok(!`${read.stdout}${read.stderr}`.includes("fixture-token"));
    });
  }
});

test("actual action accepts proven absence and refuses unreported or missing baseline wiring", async () => {
  await fixture(async ({ root, run }) => {
    const read = run(steps[0], { FIXTURE_MODE: "absent" });
    assert.equal(read.status, 0, read.stderr);
    assert.equal(JSON.parse(read.stdout).measuredEntries, 1);
    assert.equal(await readFile(join(root, "output"), "utf8"), "state=absent\nbaseline-path=\n");
    assert.equal(run(steps[1], { BASELINE_STATE: "absent" }).status, 0);
    for (const env of [{}, { BASELINE_STATE: "found" },
      { BASELINE_STATE: "found", BASELINE_FILE: join(root, "missing.json") }]) {
      const result = run(steps[1], env);
      assert.equal(result.status, 1);
      assert.match(result.stdout, /refusing policy validation/);
      assert.doesNotMatch(result.stdout, /CI latency policy: OK/);
    }
  });
});
