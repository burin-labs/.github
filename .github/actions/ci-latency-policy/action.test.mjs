import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const action = dirname(fileURLToPath(import.meta.url));
const steps = JSON.parse(execFileSync("ruby", ["-ryaml", "-rjson", "-e",
  "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]))['runs']['steps'])", join(action, "action.yml")], { encoding: "utf8" })).filter(step => typeof step.run === "string");
const sha = "a".repeat(40);
const policy = {
  schema_version: 1, repository: "burin-labs/example", workflow: "ci.yml", event: "merge_group",
  topology_epoch: "2026-08-08T00:00:00Z", full_run_jobs: [{ name: "Build", match: "exact" }],
  slo: { warning_ms: 540000, p90_ms: 600000, hard_max_ms: 900000, min_samples: 5, window_samples: 5 },
  required: { aggregate_job: "status", critical_path_allowance_ms: 600000, jobs: { build: { budget_ms: 500000 } } },
};

async function fixture(callback, sample = policy, workflow = "jobs:\n  build: {}\n  status:\n    needs: [build]\n") {
  const root = await mkdtemp(join(tmpdir(), "baseline-action-test-"));
  try {
    await writeFile(join(root, "policy.json"), JSON.stringify(sample));
    await writeFile(join(root, "workflow.yml"), workflow);
    const preload = join(root, "transport.mjs");
    await writeFile(preload, `
      const policy = ${JSON.stringify(sample)};
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
      GITHUB_ACTION_PATH: action, GITHUB_WORKSPACE: root, GITHUB_REPOSITORY: sample.repository, BASELINE_SHA: sha,
      GH_TOKEN: "fixture-token", POLICY_PATH: "policy.json", WORKFLOW_PATH: "workflow.yml",
      RUNNER_TEMP: root, GITHUB_OUTPUT: join(root, "output"), BASELINE_STATE: "", BASELINE_FILE: "" };
    const run = (step, extra = {}) => spawnSync("bash", ["-e", "-o", "pipefail", "-c", step.run],
      { cwd: root, env: { ...env, ...extra }, encoding: "utf8", timeout: 10000 });
    await callback({ root, run, env });
  } finally { await rm(root, { recursive: true, force: true }); }
}

test("actual action recovers503, emits usable atomic baseline and reaches typed budget checker", async () => {
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
    assert.match(`${refused.stdout}${refused.stderr}`, /budget may only decrease/);
    assert.ok(!`${read.stdout}${read.stderr}${checked.stdout}${checked.stderr}`.includes("fixture-token"));
  });
});

test("actual sandboxed action accepts both immutable production writer contracts and refuses a forged writer", async () => {
  for (const name of ["burin-4854778", "harn-773f11e"]) {
    const sample = JSON.parse(await readFile(join(action, "../../fixtures/ci-latency-policy", `${name}.json`), "utf8"));
    const workflow = await readFile(join(action, "../../fixtures/ci-latency-policy", `${name}.yml`), "utf8");
    await fixture(async ({ root, run }) => {
      const read = run(steps[0]);
      assert.equal(read.status, 0, read.stderr);
      const outputs = Object.fromEntries((await readFile(join(root, "output"), "utf8")).trim().split("\n").map(line => {
        const split = line.indexOf("="); return [line.slice(0, split), line.slice(split + 1)];
      }));
      const env = { BASELINE_STATE: outputs.state, BASELINE_FILE: outputs["baseline-path"] };
      const checked = run(steps[1], env);
      assert.equal(checked.status, 0, `${name}: ${checked.stdout}${checked.stderr}`);
      const census = JSON.parse(checked.stdout.trim().split("\n").at(-1));
      assert.equal(census.requiredJobCount, Object.keys(sample.required.jobs).length);
      assert.ok(census.requiredJobCount > 0);
      assert.equal(census.pendingCount, 0);
      assert.deepEqual(census.failingNames, []);
      const forged = structuredClone(sample);
      forged.observed_baseline.generator = "forged-ci-baseline-v1";
      await writeFile(join(root, "policy.json"), JSON.stringify(forged));
      const refused = run(steps[1], env);
      assert.equal(refused.status, 1, name);
      assert.match(refused.stdout, /unknown schema, writer/);
      assert.doesNotMatch(refused.stdout, /CI latency policy: OK/);
    }, sample, workflow);
  }
});

test("installed observer writer is mechanically checked by the authoritative Harn projection", async () => {
  const runs = [957000, 1052000, 1067000, 760000, 1061000].map((wall_ms, index) => {
    const started = Date.parse("2026-08-27T06:00:00Z") - index * 3600000;
    return { id: 100 - index, wall_ms, event: policy.event, conclusion: "success",
      started_at: new Date(started).toISOString(), completed_at: new Date(started + wall_ms).toISOString(),
      head_sha: (index + 1).toString(16).padStart(40, "0") };
  });
  await fixture(async ({ root, run }) => {
    const input = join(root, "writer-input.json");
    await writeFile(input, JSON.stringify({ policy, runs }));
    const writer = spawnSync("harn", ["run", "--no-sandbox",
      join(action, "../../../scripts/ci-latency/baseline-writer.harn"), "--", input],
      { encoding: "utf8" });
    assert.equal(writer.status, 0, writer.stderr);
    await writeFile(join(root, "policy.json"), JSON.stringify({
      ...policy, observed_baseline: JSON.parse(writer.stdout),
    }));
    const checked = run(steps[1], { BASELINE_SHA: "" });
    assert.equal(checked.status, 0, `${checked.stdout}${checked.stderr}`);
    assert.match(checked.stdout, /CI latency policy: OK/);
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
