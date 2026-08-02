# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ACTION_DIR = File.expand_path(__dir__)
RUNNER = File.join(ACTION_DIR, "run-contract.sh")

def invoke_contract(overrides = {})
  Dir.mktmpdir("harn-package-contract") do |directory|
    executable = File.join(directory, "harn")
    argv_receipt = File.join(directory, "argv")
    jobs_receipt = File.join(directory, "jobs")
    File.write(
      executable,
      <<~SH
        #!/usr/bin/env bash
        printf '%s\\0' "$@" > "${ARGV_RECEIPT:?}"
        printf '%s' "${HARN_TEST_JOBS-}" > "${JOBS_RECEIPT:?}"
      SH
    )
    FileUtils.chmod(0o755, executable)

    env = {
      "ARGV_RECEIPT" => argv_receipt,
      "JOBS_RECEIPT" => jobs_receipt,
      "PACKAGE_PATH" => "connector package",
      "PACKAGE_RECEIPT" => ".harn/receipts/package verify.json",
      "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
      "RUN_POLL_TICK" => "false",
      "STRICT" => "false",
      "TEST_JOBS" => "0"
    }.merge(overrides)
    stdout, stderr, status = Open3.capture3(env, RUNNER)
    argv = File.exist?(argv_receipt) ? File.binread(argv_receipt).split("\0") : []
    jobs = File.exist?(jobs_receipt) ? File.read(jobs_receipt) : nil
    { argv: argv, jobs: jobs, status: status, stderr: stderr, stdout: stdout }
  end
end

document = YAML.safe_load(File.read(File.join(ACTION_DIR, "action.yml")), aliases: true)
strict_input = document.fetch("inputs").fetch("strict")
abort "strict must remain opt-in" unless strict_input.fetch("default") == "false"
contract_step = document.fetch("runs").fetch("steps").find do |step|
  step["name"] == "Run canonical package contract"
end
abort "missing canonical contract step" unless contract_step
abort "strict input is not threaded to the boundary" unless contract_step.fetch("env").fetch("STRICT") == "${{ inputs.strict }}"
expected_runner = 'bash "$GITHUB_ACTION_PATH/run-contract.sh"'
abort "contract step must use the tested runner" unless contract_step.fetch("run") == expected_runner

default = invoke_contract
abort "default contract failed: #{default}" unless default.fetch(:status).success?
expected_default = [
  "package", "verify", "connector package", "--json", "--receipt-out",
  ".harn/receipts/package verify.json"
]
abort "default argv drifted: #{default.fetch(:argv).inspect}" unless default.fetch(:argv) == expected_default
abort "automatic test jobs must stay unset" unless default.fetch(:jobs) == ""

strict = invoke_contract("RUN_POLL_TICK" => "true", "STRICT" => "true", "TEST_JOBS" => "3")
abort "strict contract failed: #{strict}" unless strict.fetch(:status).success?
expected_strict = expected_default + ["--run-poll-tick", "--strict"]
abort "strict argv drifted: #{strict.fetch(:argv).inspect}" unless strict.fetch(:argv) == expected_strict
abort "positive test jobs must reach Harn" unless strict.fetch(:jobs) == "3"

invalid = invoke_contract("STRICT" => "yes")
abort "invalid strict value unexpectedly succeeded" if invalid.fetch(:status).success?
abort "invalid strict value must exit 2" unless invalid.fetch(:status).exitstatus == 2
abort "invalid strict value must fail before dispatch" unless invalid.fetch(:argv).empty?
abort "invalid strict error drifted" unless invalid.fetch(:stderr) == "::error::strict must be 'true' or 'false'\n"

invalid_poll = invoke_contract("RUN_POLL_TICK" => "1")
abort "invalid poll value unexpectedly succeeded" if invalid_poll.fetch(:status).success?
abort "invalid poll value must exit 2" unless invalid_poll.fetch(:status).exitstatus == 2
abort "invalid poll value must fail before dispatch" unless invalid_poll.fetch(:argv).empty?
abort "invalid poll error drifted" unless invalid_poll.fetch(:stderr) == "::error::run-poll-tick must be 'true' or 'false'\n"

invalid_jobs = invoke_contract("TEST_JOBS" => "-1")
abort "invalid test jobs unexpectedly succeeded" if invalid_jobs.fetch(:status).success?
abort "invalid test jobs must exit 2" unless invalid_jobs.fetch(:status).exitstatus == 2
abort "invalid test jobs must fail before dispatch" unless invalid_jobs.fetch(:argv).empty?
abort "invalid test jobs error drifted" unless invalid_jobs.fetch(:stderr) == "::error::test-jobs must be zero or a positive integer\n"
