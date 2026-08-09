import { appendFileSync, realpathSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

function normalize(path) {
  return path.replaceAll("\\", "/").replace(/^\.\//, "").replace(/\/+$/, "");
}

function command(program, args, options = {}) {
  const result = spawnSync(program, args, {
    cwd: options.cwd,
    encoding: options.encoding ?? "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const stderr = String(result.stderr ?? "").trim();
    throw new Error(`${program} ${args.join(" ")} failed${stderr ? `: ${stderr}` : ""}`);
  }
  return result.stdout;
}

function packageGraph(metadata, repoRoot) {
  const memberIds = new Set(metadata.workspace_members ?? []);
  const members = (metadata.packages ?? []).filter((pkg) => memberIds.has(pkg.id));
  const memberNames = new Set(members.map((pkg) => pkg.name));
  const packages = members.map((pkg) => ({
    name: pkg.name,
    dir: normalize(relative(repoRoot, dirname(pkg.manifest_path))),
    dependencies: [...new Set(
      (pkg.dependencies ?? [])
        .map((dependency) => dependency.name)
        .filter((name) => memberNames.has(name)),
    )].sort(),
  }));
  packages.sort((left, right) => left.name.localeCompare(right.name));
  return packages;
}

function owningPackage(path, packages, extraPackagePaths) {
  let owner = null;
  for (const pkg of packages) {
    if (pkg.dir === "" || path === pkg.dir || path.startsWith(`${pkg.dir}/`)) {
      if (!owner || pkg.dir.length > owner.dir.length) owner = pkg;
    }
  }
  for (const mapping of extraPackagePaths) {
    if (matchesPrefix(path, mapping.prefix)) {
      const mapped = packages.find((pkg) => pkg.name === mapping.package);
      if (!mapped) throw new Error(`extra path maps to unknown package ${mapping.package}`);
      owner = mapped;
    }
  }
  return owner;
}

function reverseDependencyClosure(seeds, packages) {
  const selected = new Set(seeds);
  let changed = true;
  while (changed) {
    changed = false;
    for (const pkg of packages) {
      if (selected.has(pkg.name)) continue;
      if (pkg.dependencies.some((dependency) => selected.has(dependency))) {
        selected.add(pkg.name);
        changed = true;
      }
    }
  }
  return [...selected].sort();
}

function matchesPrefix(path, prefix) {
  const normalized = normalize(prefix);
  return path === normalized || path.startsWith(`${normalized}/`);
}

export function planImpact({
  eventName,
  changedFiles,
  packages,
  globalPaths = [],
  extraPackagePaths = [],
}) {
  const allPackages = packages.map((pkg) => pkg.name).sort();
  if (eventName !== "pull_request") {
    return { mode: "full", packages: allPackages, reason: `${eventName} retains complete coverage` };
  }
  if (changedFiles.some((path) => globalPaths.some((prefix) => matchesPrefix(path, prefix)))) {
    return { mode: "full", packages: allPackages, reason: "a workspace-global input changed" };
  }

  const directlyChanged = new Set();
  for (const path of changedFiles) {
    const owner = owningPackage(path, packages, extraPackagePaths);
    if (owner) directlyChanged.add(owner.name);
  }
  if (directlyChanged.size === 0) {
    return { mode: "empty", packages: [], reason: "no Cargo workspace package changed" };
  }

  const selected = reverseDependencyClosure([...directlyChanged], packages);
  if (selected.length === allPackages.length) {
    return { mode: "full", packages: allPackages, reason: "the reverse-dependency closure covers the workspace" };
  }
  return {
    mode: "partial",
    packages: selected,
    reason: `changed packages and transitive reverse dependencies: ${selected.join(", ")}`,
  };
}

function changedFiles(base, head, repoRoot) {
  for (const ref of [base, head]) {
    try {
      command("git", ["cat-file", "-e", `${ref}^{commit}`], { cwd: repoRoot });
    } catch {
      command("git", ["fetch", "--no-tags", "--depth=1", "origin", ref], { cwd: repoRoot });
    }
  }
  const raw = command(
    "git",
    ["diff", "--name-status", "-z", "--find-renames", `${base}...${head}`, "--"],
    { cwd: repoRoot, encoding: "buffer" },
  );
  const fields = raw.toString("utf8").split("\0").filter(Boolean);
  const paths = [];
  for (let index = 0; index < fields.length;) {
    const status = fields[index++];
    const kind = status[0];
    if (kind === "R" || kind === "C") {
      const oldPath = fields[index++];
      const newPath = fields[index++];
      if (!oldPath || !newPath) throw new Error(`incomplete ${status} record from git diff`);
      paths.push(normalize(oldPath), normalize(newPath));
    } else {
      const path = fields[index++];
      if (!path) throw new Error(`missing path for ${status} record from git diff`);
      paths.push(normalize(path));
    }
  }
  return [...new Set(paths)].sort();
}

function writeOutput(name, value) {
  process.stdout.write(`${name}=${value}\n`);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
}

function fullPlan(packages, reason) {
  return { mode: "full", packages: packages.map((pkg) => pkg.name).sort(), reason };
}

function parseExtraPackagePaths(value, packages) {
  const packageNames = new Set(packages.map((pkg) => pkg.name));
  return value.split("\n").map((line) => line.trim()).filter(Boolean).map((line) => {
    const separator = line.indexOf("=");
    if (separator <= 0 || separator === line.length - 1) {
      throw new Error(`invalid extra package path ${JSON.stringify(line)}; expected PACKAGE=PATH_PREFIX`);
    }
    const packageName = line.slice(0, separator).trim();
    const prefix = normalize(line.slice(separator + 1).trim());
    if (!packageNames.has(packageName)) {
      throw new Error(`extra path maps to unknown package ${packageName}`);
    }
    return { package: packageName, prefix };
  });
}

function main() {
  const repoRoot = realpathSync(command("git", ["rev-parse", "--show-toplevel"]).trim());
  const workspaceInput = process.env.RUST_IMPACT_WORKSPACE || ".";
  const manifest = resolve(repoRoot, workspaceInput, "Cargo.toml");
  const metadata = JSON.parse(command(
    "cargo",
    ["metadata", "--locked", "--no-deps", "--format-version", "1", "--manifest-path", manifest],
    { cwd: repoRoot },
  ));
  const packages = packageGraph(metadata, repoRoot);
  const workspaceRoot = normalize(relative(repoRoot, metadata.workspace_root));
  const workspacePrefix = workspaceRoot ? `${workspaceRoot}/` : "";
  const globalPaths = [
    ".github/workflows",
    `${workspacePrefix}Cargo.toml`,
    `${workspacePrefix}Cargo.lock`,
    `${workspacePrefix}.cargo`,
    `${workspacePrefix}.config/nextest.toml`,
    ...(process.env.RUST_IMPACT_GLOBAL_PATHS || "").split("\n").map((path) => path.trim()).filter(Boolean),
  ];
  const extraPackagePaths = parseExtraPackagePaths(
    process.env.RUST_IMPACT_EXTRA_PACKAGE_PATHS || "",
    packages,
  );

  let plan;
  const eventName = process.env.RUST_IMPACT_EVENT_NAME || "";
  if (eventName !== "pull_request") {
    plan = fullPlan(packages, `${eventName || "unknown event"} retains complete coverage`);
  } else {
    try {
      const files = changedFiles(
        process.env.RUST_IMPACT_BASE || "",
        process.env.RUST_IMPACT_HEAD || "HEAD",
        repoRoot,
      );
      plan = planImpact({ eventName, changedFiles: files, packages, globalPaths, extraPackagePaths });
    } catch (error) {
      plan = fullPlan(packages, `impact could not be resolved safely: ${error.message}`);
    }
  }

  const packageArgs = plan.mode === "full"
    ? "--workspace"
    : plan.packages.flatMap((name) => ["-p", name]).join(" ");
  writeOutput("mode", plan.mode);
  writeOutput("packages", JSON.stringify(plan.packages));
  writeOutput("package-args", packageArgs);
  writeOutput("reason", plan.reason.replaceAll("\n", " "));
  process.stdout.write(`Rust test impact: ${plan.mode} (${plan.reason})\n`);
}

const entry = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (import.meta.url === entry) main();
