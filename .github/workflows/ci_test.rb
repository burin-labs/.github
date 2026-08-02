# frozen_string_literal: true

require "yaml"

path = File.join(__dir__, "ci.yml")
document = YAML.safe_load(File.read(path), aliases: true)
jobs = document.fetch("jobs")

smoke = jobs.fetch("package-smoke")
abort "smoke must call the local reusable workflow revision" unless smoke.fetch("uses") == "./.github/workflows/harn-package.yml"
expected_inputs = {
  "harn-version" => "0.10.50",
  "package-path" => ".github/fixtures/harn-package",
  "strict" => false,
  "artifact-name" => "harn-package-smoke-receipts"
}
abort "smoke inputs drifted" unless smoke.fetch("with") == expected_inputs

status = jobs.fetch("ci-status")
abort "CI status must always report smoke failures" unless status.fetch("if") == "${{ always() }}"
abort "CI status must own the smoke result" unless status.fetch("needs") == ["package-smoke"]
require_smoke = status.fetch("steps").find { |step| step["name"] == "Require reusable package smoke" }
abort "CI status does not require the smoke result" unless require_smoke
expected_result = "${{ needs.package-smoke.result }}"
abort "CI status reads the wrong result" unless require_smoke.fetch("env") == {"PACKAGE_SMOKE_RESULT" => expected_result}
