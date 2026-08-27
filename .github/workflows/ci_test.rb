# frozen_string_literal: true

require "yaml"

path = File.join(__dir__, "ci.yml")
document = YAML.safe_load(File.read(path), aliases: true)
jobs = document.fetch("jobs")

projection = File.read(File.expand_path("../dependabot.yml", __dir__))
template = File.read(File.expand_path("../../templates/dependabot.yml", __dir__))
abort "Dependabot projection drifted from its owning template" unless projection.start_with?(template)

smoke = jobs.fetch("package-smoke")
abort "smoke must call the local reusable workflow revision" unless smoke.fetch("uses") == "./.github/workflows/harn-package.yml"
expected_strategy = {
  "fail-fast" => false,
  "matrix" => {"strict" => [false, true]}
}
abort "smoke must exercise default and strict package policy" unless smoke.fetch("strategy") == expected_strategy
expected_inputs = {
  "harn-version" => "0.10.52",
  "package-path" => ".github/fixtures/harn-package",
  "strict" => "${{ matrix.strict }}",
  "validate-command" => "test \"$(harn --version)\" = \"harn 0.10.52\" && test -s .harn/receipts/package-verify.json",
  "artifact-name" => "harn-package-smoke-${{ matrix.strict && 'strict' || 'default' }}-receipts"
}
abort "smoke inputs drifted" unless smoke.fetch("with") == expected_inputs

status = jobs.fetch("ci-status")
abort "CI status must always report smoke failures" unless status.fetch("if") == "${{ always() }}"
abort "CI status must own the smoke result" unless status.fetch("needs") == ["package-smoke"]
steps = status.fetch("steps")
checkout = steps.find { |step| step["uses"]&.start_with?("actions/checkout@") }
expected_checkout = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
abort "CI must use the current immutable checkout action" unless checkout&.fetch("uses") == expected_checkout
abort "CI checkout must not persist credentials" unless checkout.fetch("with") == {"persist-credentials" => false}

repository_root = File.expand_path("../..", __dir__)
checkout_policy_globs = [
  File.join(__dir__, "*.{yml,yaml}"),
  File.expand_path("../actions/**/action.{yml,yaml}", __dir__)
]
policy_sources = Dir.glob(checkout_policy_globs).sort
actual_policy_sources = policy_sources.map { |path| path.delete_prefix("#{repository_root}/") }
expected_policy_sources = [
  ".github/actions/check-commit-signatures/action.yml",
  ".github/actions/check-dependabot-config/action.yml",
  ".github/actions/ci-latency-policy/action.yml",
  ".github/actions/exact-tree-ci-proof/action.yml",
  ".github/actions/harn-package/action.yml",
  ".github/actions/harn-repo-policy/action.yml",
  ".github/actions/require-successful-needs/action.yml",
  ".github/actions/rust-test-impact/action.yml",
  ".github/workflows/ci-latency-observer.yml",
  ".github/workflows/ci.yml",
  ".github/workflows/dependabot-waiver-audit.yml",
  ".github/workflows/harn-package.yml",
  ".github/workflows/merge-override-dispatch.yml",
  ".github/workflows/merge-override.yml",
  ".github/workflows/register-package-release.yml",
  ".github/workflows/reusable-pin-drift.yml",
  ".github/workflows/runner-availability.yml",
  ".github/workflows/runner-fleet-health.yml"
]
unless actual_policy_sources == expected_policy_sources
  abort "workflow/action policy source census drifted: #{actual_policy_sources.inspect}"
end

checkout_steps = policy_sources.flat_map do |policy_path|
  policy = YAML.safe_load(File.read(policy_path), aliases: true)
  step_groups = if policy.key?("jobs")
    policy.fetch("jobs").values.map { |job| job.fetch("steps", []) }
  else
    [policy.dig("runs", "steps") || []]
  end
  step_groups.flatten.select { |step| step["uses"]&.start_with?("actions/checkout@") }
end
abort "checkout policy scan must not be vacuous" if checkout_steps.empty?
unless checkout_steps.all? { |step| step.fetch("uses") == expected_checkout }
  abort "every workflow checkout must use the current immutable action"
end
unless checkout_steps.all? { |step| step.fetch("with", {}).fetch("persist-credentials", true) == false }
  abort "workflow checkouts must not persist credentials"
end

observer_path = File.join(__dir__, "ci-latency-observer.yml")
observer = YAML.safe_load(File.read(observer_path), aliases: true)
observer_events = observer.fetch(true)
abort "latency observer must run every six hours" unless observer_events.dig("schedule", 0, "cron") == "17 */6 * * *"
abort "latency observer must remain manually runnable" unless observer_events.key?("workflow_dispatch")
abort "latency observer must have read-only workflow permissions" unless observer.fetch("permissions") == {"contents" => "read"}
observe_job = observer.fetch("jobs").fetch("observe")
abort "latency observer must stay on free public hosted compute" unless observe_job.fetch("runs-on") == "ubuntu-latest"
app_step = observe_job.fetch("steps").find { |step| step["name"] == "Mint read-only release-app token" }
expected_app_permissions = {
  "permission-actions" => "read",
  "permission-contents" => "read"
}
unless app_step&.fetch("with")&.slice(*expected_app_permissions.keys) == expected_app_permissions
  abort "latency observer release-app token must remain read-only"
end
run_step = observe_job.fetch("steps").find { |step| step["name"] == "Observe full CI runs" }
runner_path = File.expand_path("../../scripts/ci_latency_observer.rb", __dir__)
runner = File.read(runner_path)
abort "latency observer must run its tested boundary" unless run_step&.fetch("run")&.include?("ruby scripts/ci_latency_observer.rb")
abort "latency observer workflow must enforce the runner verdict" unless run_step.fetch("run").include?('exit "$observer_status"')
abort "latency observer must check every governed repository" unless runner.include?('REPOSITORIES = [".github", "harn", "burin-code", "harn-cloud"].freeze')
abort "latency observer must preserve policy enforcement" unless runner.include?('"--json", "--check"')
abort "latency observer must compare against completed-run freshness" unless runner.include?("status=completed&per_page=20")
abort "latency observer must publish named failing repositories" unless runner.include?('"breaching_repositories"')
abort "latency observer must publish named pending repositories" unless runner.include?('"pending_repositories"')
abort "latency observer must publish the org report as a visible artifact file" unless runner.include?('File.join(@reports, "org-summary.json")')

markdown = steps.find { |step| step["name"] == "Markdown lint" }
expected_markdown = "DavidAnson/markdownlint-cli2-action@21c1be1b93ad9ed58fa840aacc3f279cde2a72ff"
abort "CI must lint Markdown through an immutable action" unless markdown&.fetch("uses") == expected_markdown
abort "CI must lint Markdown recursively" unless markdown.fetch("with") == {"globs" => "**/*.md"}
install_actionlint = steps.find { |step| step["name"] == "Install actionlint" }
abort "CI must install checksum-pinned actionlint" unless install_actionlint&.dig("env", "ACTIONLINT_VERSION") == "1.7.12"
abort "CI must pin the actionlint archive checksum" unless install_actionlint.dig("env", "ACTIONLINT_SHA256") == "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
actions_lint = steps.find { |step| step["name"] == "GitHub Actions lint" }
abort "CI must execute actionlint" unless actions_lint&.fetch("run") == "actionlint"

override_path = File.join(__dir__, "merge-override.yml")
override = YAML.safe_load(File.read(override_path), aliases: true)
override_steps = override.fetch("jobs").fetch("apply").fetch("steps")
cancel_step = override_steps.find { |step| step["name"] == "Cancel competing workflow runs" }
publish_step = override_steps.find { |step| step["name"] == "Publish successful CI status check" }
abort "merge override must cancel competing workflows" unless cancel_step
abort "merge override must publish its CI result" unless publish_step
unless override_steps.index(cancel_step) < override_steps.index(publish_step)
  abort "merge override must cancel workflows before publishing CI status"
end
unless cancel_step.fetch("run").include?('gh run watch "$run_id"')
  abort "merge override must wait for cancelled workflows to finish"
end
unless cancel_step.fetch("run").include?("timeout 120")
  abort "merge override cancellation wait must stay bounded"
end
unless cancel_step.fetch("run").include?('run_status="$(gh api')
  abort "merge override must confirm cancelled workflows are terminal"
end

impact_tests = steps.find { |step| step["name"] == "Test graph-derived Rust impact planning" }
unless impact_tests&.fetch("run") == "node --test .github/actions/rust-test-impact/plan.test.mjs"
  abort "CI must execute the shared Rust impact planner tests"
end

proof_tests = steps.find { |step| step["name"] == "Test exact-tree CI proof reuse" }
unless proof_tests&.fetch("run") == "bash .github/actions/exact-tree-ci-proof/run-tests.sh"
  abort "CI must execute the shared exact-tree CI proof tests"
end

policy_tests = steps.find { |step| step["name"] == "Test package workflow policy" }
abort "CI must execute repository contract tests" unless policy_tests
expected_ruby_tests = Dir.glob(
  [
    File.join(repository_root, ".github", "**", "*_test.rb"),
    File.join(repository_root, "scripts", "**", "*_test.rb"),
  ],
).map { |test| test.delete_prefix("#{repository_root}/") }.sort
declared_ruby_tests = policy_tests.fetch("run").lines.each_with_object([]) do |line, tests|
  command = line.strip
  tests << command.delete_prefix("ruby ") if command.start_with?("ruby ")
end.sort
unless declared_ruby_tests == expected_ruby_tests
  abort "CI Ruby test census drifted: declared #{declared_ruby_tests.inspect}, " \
        "expected #{expected_ruby_tests.inspect}"
end

require_smoke = status.fetch("steps").find { |step| step["name"] == "Require reusable package smoke" }
abort "CI status does not require the smoke result" unless require_smoke
expected_result = "${{ needs.package-smoke.result }}"
abort "CI status reads the wrong result" unless require_smoke.fetch("env") == {"PACKAGE_SMOKE_RESULT" => expected_result}

dependabot_check = steps.find { |step| step["name"] == "Check Dependabot config" }
abort "CI must dogfood the Dependabot delivery-policy action" unless dependabot_check
abort "CI Dependabot check must use the local composite action" unless dependabot_check.fetch("uses") == "./.github/actions/check-dependabot-config"
