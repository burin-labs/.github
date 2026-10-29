import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { readOrigin } from "./read-origin.mjs";

const caller = "example/replay";
const source = "example/source";
const base = "a".repeat(40), proof = "b".repeat(40), fixture = "c".repeat(40);
const tree = "d".repeat(40), sourceCommit = "e".repeat(40);
const policyPath = ".github/ci-latency.json", receiptPath = "evidence/replay-origin-proof.json";
const token = "fixture-token";
const gitBlob = bytes => createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
const file = (path, bytes) => ({ type: "file", path, encoding: "base64", size: bytes.length,
  sha: gitBlob(bytes), content: bytes.toString("base64") });

function world() {
  const policy = file(policyPath, Buffer.from(JSON.stringify({ repository: source })));
  const receipt = file(receiptPath, Buffer.from(JSON.stringify({ schema: "smart-ship.replay-origin.v1",
    caller_repository: caller, source_repository: source, source_commit: sourceCommit,
    fixture_base: fixture, fixture_tree: tree, source_tree: tree, policy_blob: policy.sha })));
  const commit = { sha: proof, author: { login: "burin-control[bot]" }, committer: { login: "web-flow" },
    commit: { verification: { verified: true, reason: "valid" } }, parents: [{ sha: fixture }],
    files: [{ filename: receiptPath, status: "added", sha: receipt.sha }] };
  const responses = {
    [`commits/${proof}?per_page=100`]: commit,
    [`commits/${proof}/check-runs?per_page=100`]: { total_count: 1, check_runs: [
      { name: "Smart Ship replay origin", head_sha: proof, external_id: proof,
        status: "completed", conclusion: "success", app: { id: 5413304 } },
    ] },
    [`contents/${receiptPath}?ref=${proof}`]: receipt,
    [`git/commits/${fixture}`]: { sha: fixture, tree: { sha: tree } },
    [`compare/${fixture}...${base}`]: { status: "ahead", base_commit: { sha: fixture },
      merge_base_commit: { sha: fixture } },
    [`contents/.github/ci-latency.json?ref=${base}`]: policy,
  };
  const calls = [];
  const fetch = async (url, options) => {
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    assert.equal(options.redirect, "error");
    const prefix = `https://api.github.com/repos/${caller}/`;
    assert.ok(url.startsWith(prefix));
    const key = url.slice(prefix.length);
    calls.push(key);
    return key in responses ? Response.json(responses[key]) : new Response("{}", { status: 404 });
  };
  return { responses, commit, receipt, policy, calls, fetch,
    request: { caller, base, proof, policy: policyPath, token } };
}

test("actual reader binds signed origin to caller, base ancestry and measured policy bytes", async () => {
  const w = world();
  const result = await readOrigin(w.request, { fetch: w.fetch });
  assert.equal(result.caller, caller);
  assert.equal(result.evidenceRepository, source);
  assert.equal(result.sourceCommit, sourceCommit);
  assert.equal(result.policyBlob, w.policy.sha);
  assert.equal(w.calls.length, 6);
});

test("sandboxed source gate uses the same verifier and refuses missing or duplicate captures", () => {
  const w = world();
  const responses = Object.entries(w.responses).map(([path, value]) => ({
    url: `https://api.github.com/repos/${caller}/${path}`, body: JSON.stringify(value),
  }));
  const input = { caller, base, proof, policy: policyPath, responses };
  const script = fileURLToPath(new URL("./read-origin.mjs", import.meta.url));
  const run = value => spawnSync(process.execPath, [script, "--captured-responses", caller, base, proof, policyPath, fixture],
    { input: JSON.stringify(value), encoding: "utf8", timeout: 10000 });
  const accepted = run(input);
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.equal(accepted.stdout, `${source}\n`);
  const missing = run({ ...input, responses: responses.slice(1) });
  assert.equal(missing.status, 1);
  const duplicate = run({ ...input, responses: [responses[0], responses[0], ...responses.slice(2)] });
  assert.equal(duplicate.status, 1);
  assert.equal(missing.stdout, "");
  assert.equal(duplicate.stdout, "");
});

test("missing, forged, unrelated and tampered evidence fails closed", async () => {
  const mutations = [
    w => { w.request.caller = "other/repo"; },
    w => { w.request.proof = "not-a-sha"; },
    w => { w.commit.author.login = "another-bot"; },
    w => { w.commit.committer.login = "another-committer"; },
    w => { w.commit.commit.verification.verified = false; },
    w => { w.responses[`commits/${proof}/check-runs?per_page=100`].check_runs[0].app.id = 123456; },
    w => { w.responses[`commits/${proof}/check-runs?per_page=100`].check_runs[0].head_sha = "f".repeat(40); },
    w => { w.responses[`commits/${proof}/check-runs?per_page=100`].check_runs[0].external_id = "f".repeat(40); },
    w => { w.responses[`commits/${proof}/check-runs?per_page=100`].check_runs[0].conclusion = "failure"; },
    w => { w.responses[`commits/${proof}/check-runs?per_page=100`].total_count = 2; },
    w => { delete w.responses[`commits/${proof}/check-runs?per_page=100`]; },
    w => { w.commit.files.push({ filename: "hidden", status: "added", sha: "f".repeat(40) }); },
    w => { w.commit.files[0].sha = "f".repeat(40); },
    w => { w.receipt.content = Buffer.from("tampered").toString("base64"); },
    w => { w.responses[`git/commits/${fixture}`].tree.sha = "f".repeat(40); },
    w => { w.responses[`compare/${fixture}...${base}`].merge_base_commit.sha = "f".repeat(40); },
    w => { w.policy.sha = "f".repeat(40); },
    w => { delete w.responses[`contents/${receiptPath}?ref=${proof}`]; },
  ];
  for (const mutate of mutations) {
    const w = world();
    mutate(w);
    await assert.rejects(readOrigin(w.request, { fetch: w.fetch }));
  }
});

test("a GitHub-signed receipt without control-App attestation is refused", async () => {
  const w = world();
  w.responses[`commits/${proof}/check-runs?per_page=100`] = {
    total_count: 1,
    check_runs: [{ name: "Smart Ship replay origin", head_sha: proof, external_id: proof,
      status: "completed", conclusion: "success", app: { id: 123456 } }],
  };
  await assert.rejects(readOrigin(w.request, { fetch: w.fetch }));
});

test("truncated and oversized authenticated responses are never accepted", async () => {
  const w = world();
  await assert.rejects(readOrigin(w.request, { fetch: async () =>
    new Response('{"partial":', { headers: { "content-length": "999" } }) }));
  await assert.rejects(readOrigin(w.request, { fetch: async () =>
    new Response("x".repeat(8 * 1024 * 1024 + 1)) }));
});
