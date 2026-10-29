import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const action = dirname(fileURLToPath(import.meta.url));
const definition = JSON.parse(execFileSync("ruby", ["-ryaml", "-rjson", "-e",
  "puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))", join(action, "action.yml")], { encoding: "utf8" }));
const steps = definition.runs.steps.filter(step => typeof step.run === "string");
const reader = steps.find(step => step.name === "Read the immutable CI latency baseline");
const checker = steps.find(step => step.name === "Validate declared CI latency contract");
const originReader = steps.find(step => step.name === "Verify signed historical origin");

test("ordinary callers do not invoke the optional check-run reader", () => {
  assert.equal(definition.inputs["origin-receipt-sha"].required, false);
  assert.equal(definition.inputs["origin-receipt-sha"].default, "");
  assert.equal(originReader.if, "${{ inputs.origin-receipt-sha != '' }}");
});
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
        if (mode === 'origin') {
          const responses = JSON.parse(process.env.ORIGIN_FIXTURE);
          const parsed = new URL(_url);
          const key = parsed.pathname + parsed.search;
          return Object.hasOwn(responses, key) ? Response.json(responses[key]) : new Response('{}', {status:404});
        }
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
      RUNNER_TEMP: root, GITHUB_OUTPUT: join(root, "output"), BASELINE_STATE: "", BASELINE_FILE: "",
      EVIDENCE_REPOSITORY: "" };
    const run = (step, extra = {}) => spawnSync("bash", ["-e", "-o", "pipefail", "-c", step.run],
      { cwd: root, env: { ...env, ...extra }, encoding: "utf8", timeout: 10000 });
    await callback({ root, run, env });
  } finally { await rm(root, { recursive: true, force: true }); }
}

test("actual action recovers503, emits usable atomic baseline and reaches typed budget checker", async () => {
  await fixture(async ({ root, run }) => {
    const read = run(reader, { FIXTURE_MODE: "recover" });
    assert.equal(read.status, 0, read.stderr);
    const receipt = JSON.parse(read.stdout);
    assert.equal(receipt.attempts, 2);
    assert.equal(receipt.pendingCount, 0);
    const outputs = Object.fromEntries((await readFile(join(root, "output"), "utf8")).trim().split("\n").map(line => {
      const split = line.indexOf("="); return [line.slice(0, split), line.slice(split + 1)];
    }));
    const env = { BASELINE_STATE: outputs.state, BASELINE_FILE: outputs["baseline-path"] };
    const checked = run(checker, env);
    assert.equal(checked.status, 0, checked.stderr);
    assert.match(checked.stdout, /CI latency policy: OK/);
    const loosened = structuredClone(policy);
    loosened.required.jobs.build.budget_ms += 1;
    await writeFile(join(root, "policy.json"), JSON.stringify(loosened));
    const refused = run(checker, env);
    assert.equal(refused.status, 1);
    assert.match(`${refused.stdout}${refused.stderr}`, /budget may only decrease/);
    assert.ok(!`${read.stdout}${read.stderr}${checked.stdout}${checked.stderr}`.includes("fixture-token"));
  });
});

test("actual action binds a signed historical origin while preserving caller and budget refusals", async () => {
  const caller = "example/replay", base = "a".repeat(40), proof = "b".repeat(40);
  const fixtureBase = "c".repeat(40), tree = "d".repeat(40), sourceCommit = "e".repeat(40);
  const sourcePolicy = structuredClone(policy);
  const bytes = Buffer.from(JSON.stringify(sourcePolicy));
  const blob = data => createHash("sha1").update(`blob ${data.length}\0`).update(data).digest("hex");
  const githubFile = (path, data) => ({ type: "file", path, encoding: "base64", size: data.length,
    sha: blob(data), content: data.toString("base64") });
  const baseFile = githubFile("policy.json", bytes);
  const receiptPath = "evidence/replay-origin-proof.json";
  const receipt = githubFile(receiptPath, Buffer.from(JSON.stringify({ schema: "smart-ship.replay-origin.v1",
    caller_repository: caller, source_repository: sourcePolicy.repository, source_commit: sourceCommit,
    fixture_base: fixtureBase, fixture_tree: tree, source_tree: tree, policy_blob: baseFile.sha })));
  const prefix = `/repos/${caller}/`;
  const responses = {
    [`${prefix}commits/${proof}?per_page=100`]: { sha: proof, author: { login: "burin-control[bot]" },
      committer: { login: "web-flow" }, commit: { verification: { verified: true, reason: "valid" } },
      parents: [{ sha: fixtureBase }], files: [{ filename: receiptPath, status: "added", sha: receipt.sha }] },
    [`${prefix}commits/${proof}/check-runs?per_page=100`]: { total_count: 1, check_runs: [
      { name: "Smart Ship replay origin", head_sha: proof, external_id: proof,
        status: "completed", conclusion: "success", app: { id: 5413304 } },
    ] },
    [`${prefix}contents/${receiptPath}?ref=${proof}`]: receipt,
    [`${prefix}git/commits/${fixtureBase}`]: { sha: fixtureBase, tree: { sha: tree } },
    [`${prefix}compare/${fixtureBase}...${base}`]: { status: "ahead", base_commit: { sha: fixtureBase },
      merge_base_commit: { sha: fixtureBase } },
    [`${prefix}contents/policy.json?ref=${base}`]: baseFile,
  };
  await fixture(async ({ root, run }) => {
    const baseline = run(reader, { GITHUB_REPOSITORY: caller, BASELINE_SHA: base });
    assert.equal(baseline.status, 0, baseline.stderr);
    const origin = run(originReader, { GITHUB_REPOSITORY: caller, BASELINE_SHA: base,
      ORIGIN_RECEIPT_SHA: proof, FIXTURE_MODE: "origin", ORIGIN_FIXTURE: JSON.stringify(responses) });
    assert.equal(origin.status, 0, origin.stderr);
    const outputs = Object.fromEntries((await readFile(join(root, "output"), "utf8")).trim().split("\n").map(line => {
      const split = line.indexOf("="); return [line.slice(0, split), line.slice(split + 1)];
    }));
    const env = { GITHUB_REPOSITORY: caller, BASELINE_SHA: base, BASELINE_STATE: outputs.state,
      BASELINE_FILE: outputs["baseline-path"], EVIDENCE_REPOSITORY: outputs["evidence-repository"] };
    assert.equal(env.EVIDENCE_REPOSITORY, sourcePolicy.repository);
    const accepted = run(checker, env);
    assert.equal(accepted.status, 0, accepted.stdout + accepted.stderr);
    const ordinary = run(checker, { ...env, EVIDENCE_REPOSITORY: "" });
    assert.equal(ordinary.status, 1);
    assert.match(ordinary.stdout, /policy repository does not match caller/);
    const loosened = structuredClone(sourcePolicy);
    loosened.required.jobs.build.budget_ms += 1;
    await writeFile(join(root, "policy.json"), JSON.stringify(loosened));
    const widened = run(checker, env);
    assert.equal(widened.status, 1);
    assert.match(widened.stdout, /budget may only decrease/);
    const forged = structuredClone(responses);
    forged[`${prefix}commits/${proof}?per_page=100`].author.login = "other-bot";
    const refused = run(originReader, { GITHUB_REPOSITORY: caller, BASELINE_SHA: base,
      ORIGIN_RECEIPT_SHA: proof, FIXTURE_MODE: "origin", ORIGIN_FIXTURE: JSON.stringify(forged) });
    assert.equal(refused.status, 1);
    assert.match(refused.stderr, /historical origin evidence was refused/);
    const wrongApp = structuredClone(responses);
    wrongApp[`${prefix}commits/${proof}/check-runs?per_page=100`].check_runs[0].app.id = 123456;
    const untrusted = run(originReader, { GITHUB_REPOSITORY: caller, BASELINE_SHA: base,
      ORIGIN_RECEIPT_SHA: proof, FIXTURE_MODE: "origin", ORIGIN_FIXTURE: JSON.stringify(wrongApp) });
    assert.equal(untrusted.status, 1);
    assert.match(untrusted.stderr, /historical origin evidence was refused/);
  }, sourcePolicy);
});

test("actual sandboxed action accepts both immutable production writer contracts and refuses a forged writer", async () => {
  for (const name of ["burin-4854778", "harn-773f11e"]) {
    const sample = JSON.parse(await readFile(join(action, "../../fixtures/ci-latency-policy", `${name}.json`), "utf8"));
    const workflow = await readFile(join(action, "../../fixtures/ci-latency-policy", `${name}.yml`), "utf8");
    await fixture(async ({ root, run }) => {
      const read = run(reader);
      assert.equal(read.status, 0, read.stderr);
      const outputs = Object.fromEntries((await readFile(join(root, "output"), "utf8")).trim().split("\n").map(line => {
        const split = line.indexOf("="); return [line.slice(0, split), line.slice(split + 1)];
      }));
      const env = { BASELINE_STATE: outputs.state, BASELINE_FILE: outputs["baseline-path"] };
      const checked = run(checker, env);
      assert.equal(checked.status, 0, `${name}: ${checked.stdout}${checked.stderr}`);
      const census = JSON.parse(checked.stdout.trim().split("\n").at(-1));
      assert.equal(census.requiredJobCount, Object.keys(sample.required.jobs).length);
      assert.ok(census.requiredJobCount > 0);
      assert.equal(census.pendingCount, 0);
      assert.deepEqual(census.failingNames, []);
      const forged = structuredClone(sample);
      forged.observed_baseline.generator = "forged-ci-baseline-v1";
      await writeFile(join(root, "policy.json"), JSON.stringify(forged));
      const refused = run(checker, env);
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
    const checked = run(checker, { BASELINE_SHA: "" });
    assert.equal(checked.status, 0, `${checked.stdout}${checked.stderr}`);
    assert.match(checked.stdout, /CI latency policy: OK/);
  });
});

test("actual CLI failure leaves neither outputs nor a replacement baseline", async () => {
  for (const mode of ["exhausted", "denied", "partial"]) {
    await fixture(async ({ root, run }) => {
      const baseline = join(root, "ci-latency-baseline.json");
      await writeFile(baseline, "previous qualified baseline");
      const read = run(reader, { FIXTURE_MODE: mode });
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
    const read = run(reader, { FIXTURE_MODE: "absent" });
    assert.equal(read.status, 0, read.stderr);
    assert.equal(JSON.parse(read.stdout).measuredEntries, 1);
    assert.equal(await readFile(join(root, "output"), "utf8"), "state=absent\nbaseline-path=\n");
    assert.equal(run(checker, { BASELINE_STATE: "absent" }).status, 0);
    for (const env of [{}, { BASELINE_STATE: "found" },
      { BASELINE_STATE: "found", BASELINE_FILE: join(root, "missing.json") }]) {
      const result = run(checker, env);
      assert.equal(result.status, 1);
      assert.match(result.stdout, /refusing policy validation/);
      assert.doesNotMatch(result.stdout, /CI latency policy: OK/);
    }
  });
});
