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
steps = status.fetch("steps")
checkout = steps.find { |step| step["uses"]&.start_with?("actions/checkout@") }
expected_checkout = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
abort "CI must use the current immutable checkout action" unless checkout&.fetch("uses") == expected_checkout
abort "CI checkout must not persist credentials" unless checkout.fetch("with") == {"persist-credentials" => false}
markdown = steps.find { |step| step["name"] == "Markdown lint" }
expected_markdown = "DavidAnson/markdownlint-cli2-action@6bf21b07787794f89a243495939cd651942aeabe"
abort "CI must lint Markdown through an immutable action" unless markdown&.fetch("uses") == expected_markdown
install_actionlint = steps.find { |step| step["name"] == "Install actionlint" }
abort "CI must install checksum-pinned actionlint" unless install_actionlint&.dig("env", "ACTIONLINT_VERSION") == "1.7.12"
abort "CI must pin the actionlint archive checksum" unless install_actionlint.dig("env", "ACTIONLINT_SHA256") == "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
actions_lint = steps.find { |step| step["name"] == "GitHub Actions lint" }
abort "CI must execute actionlint" unless actions_lint&.fetch("run") == "actionlint-bin"
require_smoke = status.fetch("steps").find { |step| step["name"] == "Require reusable package smoke" }
abort "CI status does not require the smoke result" unless require_smoke
expected_result = "${{ needs.package-smoke.result }}"
abort "CI status reads the wrong result" unless require_smoke.fetch("env") == {"PACKAGE_SMOKE_RESULT" => expected_result}
