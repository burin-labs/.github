# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ACTION_DIR = File.expand_path(__dir__)
RUNNER = File.join(ACTION_DIR, "run.sh")

def invoke_runner(overrides = {})
  Dir.mktmpdir("local-workflow-checks-action") do |directory|
    executable = File.join(directory, "harn")
    argv_receipt = File.join(directory, "argv")
    File.write(
      executable,
      <<~SH
        #!/usr/bin/env bash
        printf '%s\\0' "$@" > "${ARGV_RECEIPT:?}"
      SH
    )
    FileUtils.chmod(0o755, executable)
    env = {
      "ARGV_RECEIPT" => argv_receipt,
      "GITHUB_ACTION_PATH" => ACTION_DIR,
      "LOCAL_CHECK_WORKFLOW" => ".github/workflows/ci.yml",
      "LOCAL_CHECK_POLICY" => ".github/local-checks.json",
      "LOCAL_CHECK_ROOT" => "/workspace",
      "LOCAL_CHECK_PLATFORM" => "",
      "LOCAL_CHECK_BUILD_WRAPPER" => "",
      "LOCAL_CHECK_GROUP" => "",
      "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
    }.merge(overrides)
    _stdout, stderr, status = Open3.capture3(env, RUNNER)
    argv = File.exist?(argv_receipt) ? File.binread(argv_receipt).split("\0") : []
    toolchain_roots = env.fetch("PATH").split(File::PATH_SEPARATOR).select do |path|
      !path.empty? && Dir.exist?(path)
    end
    {argv: argv, status: status, stderr: stderr, toolchain_roots: toolchain_roots}
  end
end

document = YAML.safe_load(File.read(File.join(ACTION_DIR, "action.yml")), aliases: true)
setup = document.fetch("runs").fetch("steps").find { |step| step["id"] == "setup" }
abort "missing Harn setup step" unless setup
setup_reference = setup.fetch("uses")
unless setup_reference.match?(%r{\Aburin-labs/harn/\.github/actions/setup-harn@[0-9a-f]{40}\z})
  abort "Harn setup action must use an immutable commit"
end
run_step = document.fetch("runs").fetch("steps").find do |step|
  step["name"] == "Run workflow-derived checks"
end
abort "missing workflow check step" unless run_step
abort "action must call the tested runner" unless run_step.fetch("run") == 'bash "$GITHUB_ACTION_PATH/run.sh"'

default = invoke_runner
abort "default runner failed: #{default}" unless default.fetch(:status).success?
package_root = File.expand_path("../../..", ACTION_DIR)
expected = [
  "run", "--standalone", "--read-only-root", package_root, "--write-root", "/workspace",
] + default.fetch(:toolchain_roots).flat_map { |path| ["--sandbox-read-root", path] } + [
  File.join(package_root, "scripts/local-checks/cli.harn"), "--",
  "--workflow", ".github/workflows/ci.yml",
  "--policy", ".github/local-checks.json",
  "--root", "/workspace",
]
abort "default runner argv drifted: #{default.fetch(:argv).inspect}" unless default.fetch(:argv) == expected

overridden = invoke_runner(
  "LOCAL_CHECK_PLATFORM" => "linux",
  "LOCAL_CHECK_BUILD_WRAPPER" => "build-lock.sh,env,CARGO_BUILD_JOBS=4",
  "LOCAL_CHECK_GROUP" => "precommit",
)
abort "overridden runner failed: #{overridden}" unless overridden.fetch(:status).success?
expected_overridden = [
  "run", "--standalone", "--read-only-root", package_root, "--write-root", "/workspace",
] + overridden.fetch(:toolchain_roots).flat_map { |path| ["--sandbox-read-root", path] } + [
  File.join(package_root, "scripts/local-checks/cli.harn"), "--",
  "--workflow", ".github/workflows/ci.yml",
  "--policy", ".github/local-checks.json",
  "--root", "/workspace",
  "--platform", "linux",
  "--build-wrapper", "build-lock.sh,env,CARGO_BUILD_JOBS=4",
  "--group", "precommit",
]
unless overridden.fetch(:argv) == expected_overridden
  abort "override runner argv drifted: #{overridden.fetch(:argv).inspect}"
end

missing = invoke_runner("LOCAL_CHECK_POLICY" => "")
abort "missing policy unexpectedly succeeded" if missing.fetch(:status).success?
abort "missing policy must fail before Harn dispatch" unless missing.fetch(:argv).empty?
