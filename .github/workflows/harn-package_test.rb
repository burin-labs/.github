# frozen_string_literal: true

require "yaml"

path = File.join(__dir__, "harn-package.yml")
document = YAML.safe_load(File.read(path), aliases: true)
steps = document.fetch("jobs").fetch("verify").fetch("steps")

policy = steps.find { |step| step["name"] == "Check repository projections" }
abort "missing repository projection step" unless policy
expected_scope = "${{ github.repository_owner == 'burin-labs' }}"
abort "repository policy must be scoped to Burin Labs callers" unless policy["if"] == expected_scope

package = steps.find { |step| step["name"] == "Verify package" }
abort "missing package verification step" unless package
abort "package verification must remain universal" if package.key?("if")

strict = document.fetch(true).fetch("workflow_call").fetch("inputs").fetch("strict")
abort "strict package policy must be a boolean input" unless strict["type"] == "boolean"
abort "strict package policy must stay opt-in" unless strict["default"] == false

forwarded_strict = package.fetch("with").fetch("strict")
expected_strict = "${{ inputs.strict }}"
abort "workflow must delegate strict policy to the package action" unless forwarded_strict == expected_strict

action_path = File.join(__dir__, "..", "actions", "harn-package", "action.yml")
action = YAML.safe_load(File.read(action_path), aliases: true)
abort "package action must expose strict policy" unless action.fetch("inputs").key?("strict")

contract = action.fetch("runs").fetch("steps").find do |step|
  step["name"] == "Run canonical package contract"
end
abort "missing canonical package contract step" unless contract
abort "strict input must be passed at the command boundary" unless contract.fetch("env")["STRICT"] == "${{ inputs.strict }}"
expected_runner = 'bash "$GITHUB_ACTION_PATH/run-contract.sh"'
abort "package contract must route through its tested runner" unless contract.fetch("run") == expected_runner
