import { createHash } from "node:crypto";
import { appendFile, mkdtemp, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const shaPattern = /^[0-9a-f]{40}$/;
const repoPattern = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const receiptPath = "evidence/replay-origin-proof.json";
const maxBytes = 8 * 1024 * 1024;

function repository(value) {
  return typeof value === "string" && repoPattern.test(value)
    && !value.split("/").some(part => part === "." || part === "..");
}

function requireValue(condition, message) {
  if (!condition) throw new Error(`historical origin refused: ${message}`);
}

function blobSha(bytes) {
  return createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
}

function content(file, path) {
  requireValue(file && file.type === "file" && file.path === path && file.encoding === "base64"
    && typeof file.content === "string" && shaPattern.test(file.sha || ""), "unmeasured content");
  const encoded = file.content.replace(/\s/g, "");
  requireValue(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded),
    "malformed base64");
  const bytes = Buffer.from(encoded, "base64");
  requireValue(bytes.length > 0 && bytes.length <= maxBytes && bytes.length === file.size
    && blobSha(bytes) === file.sha, "content digest or size mismatch");
  return bytes;
}

/** Validate a control-signed receipt against authenticated reads from the actual caller. */
export async function readOrigin(request, { fetch = globalThis.fetch, capture = () => {} } = {}) {
  const { caller, base, proof, policy, token } = request;
  requireValue(repository(caller) && shaPattern.test(base || "") && shaPattern.test(proof || "")
    && /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/.test(policy || "")
    && !policy.split("/").some(part => part === "." || part === "..")
    && typeof token === "string" && token.length > 0, "invalid input identity");
  async function get(endpoint) {
    const url = `https://api.github.com/repos/${caller}/${endpoint}`;
    let response;
    try {
      response = await fetch(url, {
        headers: { Accept: "application/vnd.github+json", Authorization: `Bearer ${token}`,
          "X-GitHub-Api-Version": "2022-11-28" },
        redirect: "error", signal: AbortSignal.timeout(20000),
      });
    } catch {
      throw new Error("historical origin refused: incomplete transport");
    }
    requireValue(response?.status === 200 && typeof response.body?.getReader === "function"
      && typeof response.headers?.get === "function", "missing authenticated evidence");
    const reader = response.body.getReader();
    const chunks = [];
    let measured = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        requireValue(value instanceof Uint8Array && value.byteLength > 0, "incomplete response");
        measured += value.byteLength;
        requireValue(measured <= maxBytes, "response exceeds byte limit");
        chunks.push(value);
      }
    } catch {
      await reader.cancel().catch(() => {});
      throw new Error("historical origin refused: incomplete or oversized response");
    }
    const declared = response.headers.get("content-length");
    const encoding = response.headers.get("content-encoding");
    requireValue(measured > 0 && ((!encoding || encoding === "identity") && declared !== null
      ? /^[0-9]+$/.test(declared) && Number(declared) === measured : true), "invalid response size");
    const bytes = Buffer.concat(chunks, measured);
    let value, body;
    try { body = new TextDecoder("utf-8", { fatal: true }).decode(bytes); value = JSON.parse(body); }
    catch { throw new Error("historical origin refused: incomplete JSON"); }
    requireValue(value && typeof value === "object" && !Array.isArray(value), "invalid response shape");
    capture(url, body);
    return value;
  }
  const commit = await get(`commits/${proof}?per_page=100`);
  requireValue(commit.sha === proof && commit.author?.login === "burin-control[bot]"
    && commit.committer?.login === "web-flow" && commit.commit?.verification?.verified === true
    && commit.commit?.verification?.reason === "valid" && Array.isArray(commit.parents)
    && commit.parents.length === 1 && Array.isArray(commit.files) && commit.files.length === 1
    && commit.files[0].filename === receiptPath && commit.files[0].status === "added"
    && shaPattern.test(commit.files[0].sha || ""), "untrusted or incomplete signed receipt");
  const file = await get(`contents/${receiptPath}?ref=${proof}`);
  requireValue(file.sha === commit.files[0].sha, "receipt blob does not match its signed commit");
  let receipt;
  try { receipt = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(content(file, receiptPath))); }
  catch { throw new Error("historical origin refused: invalid receipt"); }
  requireValue(receipt?.schema === "smart-ship.replay-origin.v1" && receipt.caller_repository === caller
    && repository(receipt.source_repository) && shaPattern.test(receipt.source_commit || "")
    && shaPattern.test(receipt.fixture_base || "") && shaPattern.test(receipt.fixture_tree || "")
    && receipt.fixture_tree === receipt.source_tree && shaPattern.test(receipt.policy_blob || "")
    && commit.parents[0].sha === receipt.fixture_base, "receipt identity mismatch");
  const fixture = await get(`git/commits/${receipt.fixture_base}`);
  requireValue(fixture.sha === receipt.fixture_base && fixture.tree?.sha === receipt.fixture_tree,
    "fixture tree mismatch");
  const comparison = await get(`compare/${receipt.fixture_base}...${base}`);
  requireValue(comparison.base_commit?.sha === receipt.fixture_base
    && comparison.merge_base_commit?.sha === receipt.fixture_base
    && ["identical", "ahead"].includes(comparison.status),
    "fixture is not the base or its ancestor");
  const policyFile = await get(`contents/${policy.split("/").map(encodeURIComponent).join("/")}?ref=${base}`);
  const policyBytes = content(policyFile, policy);
  requireValue(policyFile.sha === receipt.policy_blob, "baseline policy differs from signed source");
  let baseline;
  try { baseline = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(policyBytes)); }
  catch { throw new Error("historical origin refused: invalid baseline policy"); }
  requireValue(baseline?.repository === receipt.source_repository, "baseline source differs from receipt");
  return { caller, base, proof, evidenceRepository: receipt.source_repository,
    sourceCommit: receipt.source_commit, fixtureBase: receipt.fixture_base, policyBlob: receipt.policy_blob };
}

async function main() {
  requireValue(typeof process.env.GITHUB_OUTPUT === "string" && process.env.GITHUB_OUTPUT.length > 0,
    "missing output path");
  requireValue(typeof process.env.RUNNER_TEMP === "string" && process.env.RUNNER_TEMP.length > 0,
    "missing runner temp");
  const request = { caller: process.env.GITHUB_REPOSITORY, base: process.env.BASELINE_SHA,
    proof: process.env.ORIGIN_RECEIPT_SHA, policy: process.env.POLICY_PATH, token: process.env.GH_TOKEN };
  const responses = [];
  const result = await readOrigin(request, { capture: (url, body) => responses.push({ url, body }) });
  requireValue(responses.length === 5, "incomplete response census");
  const captured = JSON.stringify({ caller: request.caller, base: request.base, proof: request.proof,
    policy: request.policy, responses });
  const captureRoot = await mkdtemp(join(process.env.RUNNER_TEMP, "ci-origin-"));
  const capturePath = join(captureRoot, "responses.json");
  await writeFile(capturePath, captured, { mode: 0o600, flag: "wx" });
  const captureSha = createHash("sha256").update(captured).digest("hex");
  const verifierPath = fileURLToPath(import.meta.url);
  await appendFile(process.env.GITHUB_OUTPUT, `evidence-repository=${result.evidenceRepository}\n` +
    `verifier-path=${verifierPath}\nverifier-root=${dirname(verifierPath)}\n` +
    `capture-path=${capturePath}\ncapture-root=${captureRoot}\ncapture-sha256=${captureSha}\n`);
  console.log(JSON.stringify({ ...result, pendingCount: 0, failingNames: [] }));
}

// The sandboxed source gate reads the authenticated API itself and passes the
// measured responses here. This is the same verifier as the composite action;
// no GitHub token or network permission is passed to the child process.
async function verifyCapturedResponses() {
  const chunks = [];
  let total = 0;
  for await (const chunk of process.stdin) {
    total += chunk.length;
    requireValue(total <= 5 * maxBytes + 8192, "captured evidence is oversized");
    chunks.push(chunk);
  }
  let input;
  try { input = JSON.parse(Buffer.concat(chunks, total).toString("utf8")); }
  catch { throw new Error("historical origin refused: invalid captured evidence"); }
  requireValue(process.argv.length === 8 && input.caller === process.argv[3] && input.base === process.argv[4]
    && input.proof === process.argv[5] && input.policy === process.argv[6], "captured identity mismatch");
  requireValue(Array.isArray(input.responses) && input.responses.length === 5, "incomplete response census");
  const result = await readOrigin({ caller: input.caller, base: input.base, proof: input.proof,
    policy: input.policy, token: "captured-responses-only" }, { fetch: async url => {
    const found = input.responses.filter(item => item.url === url && typeof item.body === "string");
    requireValue(found.length === 1, "missing or duplicate captured response");
    return new Response(found[0].body, { status: 200 });
  } });
  requireValue(result.fixtureBase === process.argv[7], "captured fixture mismatch");
  process.stdout.write(`${result.evidenceRepository}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const operation = process.argv[2] === "--captured-responses" ? verifyCapturedResponses : main;
  operation().catch(() => {
    console.error(JSON.stringify({ pendingCount: 1, failingNames: ["historical-origin"],
      reason: "historical origin evidence was refused" }));
    process.exitCode = 1;
  });
}
