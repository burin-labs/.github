import { appendFile, mkdir, mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { performance } from "node:perf_hooks";

const transientStatuses = new Set([408, 429, 500, 502, 503, 504]);
const maxAttempts = 3;
const maxBytes = 8 * 1024 * 1024;
const requestTimeoutMs = 20_000;
const totalTimeoutMs = 60_000;

function required(value, name) {
  if (typeof value !== "string" || value.length === 0 || /[\r\n]/.test(value)) {
    throw new Error(`${name} is required and must be one line`);
  }
  return value;
}

function identity(repository, policy, sha) {
  required(repository, "repository");
  required(policy, "policy");
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
      repository.split("/").some(part => part === "." || part === "..")) {
    throw new Error("repository must be an owner/name identity");
  }
  if (!/^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/.test(policy) ||
      policy.split("/").some(part => part === "." || part === "..")) {
    throw new Error("policy must be a canonical repository-relative path");
  }
  if (typeof sha !== "string" || !/^[0-9a-f]{40}$/.test(sha)) {
    throw new Error("baseline-sha must be an immutable 40-digit commit identity");
  }
  return { repository, policy, sha };
}

async function jsonBody(response) {
  if (!response.body || typeof response.body.getReader !== "function") {
    throw new Error("baseline response body is unmeasured");
  }
  const reader = response.body.getReader();
  const chunks = [];
  let measuredBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array) || value.byteLength === 0) {
        throw new Error("baseline body made no measured progress");
      }
      measuredBytes += value.byteLength;
      if (measuredBytes > maxBytes) throw new Error("baseline response exceeds its byte limit");
      chunks.push(value);
    }
  } catch {
    await reader.cancel().catch(() => {});
    throw new Error("baseline body is incomplete or exceeds its byte limit");
  }
  if (measuredBytes === 0) throw new Error("baseline response body is empty");
  const bytes = Buffer.concat(chunks, measuredBytes);
  const encoding = response.headers.get("content-encoding");
  const declared = response.headers.get("content-length");
  if ((!encoding || encoding === "identity") && declared !== null &&
      (!/^[0-9]+$/.test(declared) || Number(declared) !== measuredBytes)) {
    throw new Error("baseline body length disagrees with the response");
  }
  let value;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new Error("baseline body is not complete UTF-8 JSON");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).length === 0) {
    throw new Error("baseline JSON must be a non-null measured object");
  }
  return { value, bytes, measuredBytes };
}

/** Bootstrap transport only. The existing policy checker owns all budget rules. */
export async function readBaseline(request, {
  fetch = globalThis.fetch,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  now = () => performance.now(),
} = {}) {
  if (typeof fetch !== "function" || typeof globalThis.AbortSignal?.timeout !== "function") {
    throw new Error("immutable baseline reader requires an existing Node runtime with fetch and AbortSignal.timeout");
  }
  const source = identity(request.repository, request.policy, request.sha);
  const token = required(request.token, "github-token");
  const deadline = now() + totalTimeoutMs;
  let attempts = 0;
  async function waitForRetry(attempt, retryAfter) {
    let delay = attempt * 1000;
    if (retryAfter !== null) {
      if (!/^[0-9]+$/.test(retryAfter)) throw new Error("immutable baseline Retry-After is unmeasured; pending=1");
      delay = Math.max(delay, Number(retryAfter) * 1000);
    }
    if (!Number.isSafeInteger(delay) || delay >= deadline - now()) {
      throw new Error("immutable baseline retry cannot fit its deadline; pending=1");
    }
    await sleep(delay);
  }
  async function get(endpoint, accept) {
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      const remaining = deadline - now();
      if (remaining <= 0) throw new Error("immutable baseline deadline exhausted; pending=1");
      let response;
      attempts += 1;
      try {
        response = await fetch(`https://api.github.com/repos/${source.repository}/${endpoint}`, {
          headers: { Accept: accept, Authorization: `Bearer ${token}`, "X-GitHub-Api-Version": "2022-11-28" },
          redirect: "error",
          signal: AbortSignal.timeout(Math.max(1, Math.floor(Math.min(remaining, requestTimeoutMs)))),
        });
      } catch {
        if (attempt === maxAttempts) {
          throw new Error(`immutable baseline transport exhausted ${attempt} attempts; pending=1`);
        }
        await waitForRetry(attempt, null);
        continue;
      }
      if (!Number.isInteger(response?.status) || response.status < 100 || response.status > 599 ||
          typeof response.headers?.get !== "function") {
        throw new Error("immutable baseline HTTP status is unmeasured; pending=1");
      }
      if (!transientStatuses.has(response.status)) return response;
      await response.body?.cancel().catch(() => {});
      if (attempt === maxAttempts) {
        throw new Error(`immutable baseline HTTP ${response.status} exhausted ${attempt} attempts; pending=1`);
      }
      await waitForRetry(attempt, response.headers.get("retry-after"));
    }
    throw new Error("immutable baseline attempts are unmeasured; pending=1");
  }
  async function requireJson(endpoint) {
    const response = await get(endpoint, "application/vnd.github+json");
    if (response.status !== 200) throw new Error(`immutable baseline census HTTP ${response.status}; pending=1`);
    return (await jsonBody(response)).value;
  }
  const path = source.policy.split("/").map(encodeURIComponent).join("/");
  const response = await get(`contents/${path}?ref=${source.sha}`, "application/vnd.github.raw+json");
  if (response.status === 200) {
    const body = await jsonBody(response);
    return { state: "found", source, attempts, measuredBytes: body.measuredBytes, bytes: body.bytes, pendingCount: 0 };
  }
  if (response.status !== 404) {
    throw new Error(`immutable baseline HTTP ${response.status}; pending=1`);
  }
  await response.body?.cancel().catch(() => {});
  const commit = await requireJson(`git/commits/${source.sha}`);
  if (commit.sha !== source.sha || typeof commit.tree?.sha !== "string" || !/^[0-9a-f]{40}$/.test(commit.tree.sha)) {
    throw new Error("immutable baseline commit identity is unmeasured; pending=1");
  }
  const tree = await requireJson(`git/trees/${commit.tree.sha}?recursive=1`);
  if (tree.sha !== commit.tree.sha || tree.truncated !== false || !Array.isArray(tree.tree) || tree.tree.length === 0 ||
      tree.tree.some(entry => typeof entry?.path !== "string" || entry.path.length === 0 ||
        !["blob", "tree", "commit"].includes(entry.type)) ||
      new Set(tree.tree.map(entry => entry.path)).size !== tree.tree.length) {
    throw new Error("immutable baseline tree is partial or unmeasured; pending=1");
  }
  if (tree.tree.some(entry => entry.path === source.policy)) {
    throw new Error("immutable baseline exists in its tree but contents retrieval failed; pending=1");
  }
  return { state: "absent", source, attempts, measuredEntries: tree.tree.length, pendingCount: 0 };
}

export async function publishBaseline(result, destination) {
  if (result.state !== "found") throw new Error("only a measured baseline may be published");
  await mkdir(dirname(destination), { recursive: true });
  const scratch = await mkdtemp(join(dirname(destination), ".ci-latency-baseline-"));
  try {
    const staged = join(scratch, "baseline.json");
    await writeFile(staged, result.bytes, { mode: 0o600, flag: "wx" });
    await rename(staged, destination);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}

async function main() {
  const output = required(process.env.GITHUB_OUTPUT, "GITHUB_OUTPUT");
  const destination = join(required(process.env.RUNNER_TEMP, "RUNNER_TEMP"), "ci-latency-baseline.json");
  const result = await readBaseline({ repository: process.env.GITHUB_REPOSITORY, policy: process.env.POLICY_PATH,
    sha: process.env.BASELINE_SHA, token: process.env.GH_TOKEN });
  if (result.state === "found") await publishBaseline(result, destination);
  await appendFile(output,
    `state=${result.state}\nbaseline-path=${result.state === "found" ? destination : ""}\n`);
  console.log(JSON.stringify({ state: result.state, source: result.source, attempts: result.attempts,
    pendingCount: result.pendingCount, failingNames: [], measuredBytes: result.measuredBytes,
    measuredEntries: result.measuredEntries }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    console.error(JSON.stringify({ state: "refused", pendingCount: 1,
      failingNames: ["immutable-baseline"], reason: error.message }));
    process.exitCode = 1;
  });
}
