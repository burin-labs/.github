# frozen_string_literal: true

require "yaml"

path = File.join(__dir__, "harn-package.yml")
document = YAML.safe_load(File.read(path), aliases: true)
steps = document.fetch("jobs").fetch("verify").fetch("steps")

package_checkout = steps.find { |step| step["name"] == "Check out package" }
abort "missing package checkout" unless package_checkout
unless package_checkout.fetch("with") == {"persist-credentials" => false}
  abort "package checkout must not persist the caller credential"
end

policy = steps.find { |step| step["name"] == "Check repository projections" }
abort "missing repository projection step" unless policy
expected_scope =
  "${{ github.repository_owner == 'burin-labs' && " \
  "(github.repository != 'burin-labs/.github' || " \
  "inputs.package-path != '.github/fixtures/harn-package') }}"
unless policy["if"] == expected_scope
  abort "repository policy must be scoped to Burin Labs callers and the exact local smoke fixture"
end

package = steps.find { |step| step["name"] == "Verify package" }
abort "missing package verification step" unless package
abort "package verification must remain universal" if package.key?("if")

validation = steps.find { |step| step["name"] == "Run caller validation" }
abort "missing caller validation boundary" unless validation
validate_input = document.fetch(true).fetch("workflow_call").fetch("inputs").fetch("validate-command")
expected_validate_input = {
  "description" => "Caller-owned verification run after the canonical package contract.",
  "required" => false,
  "default" => "",
  "type" => "string"
}
abort "caller validation input drifted" unless validate_input == expected_validate_input
abort "caller validation must remain optional" unless validation.fetch("if") == "${{ inputs.validate-command != '' }}"
expected_validation_env = {"PACKAGE_VALIDATE_COMMAND" => "${{ inputs.validate-command }}"}
abort "caller validation must cross one named environment boundary" unless validation.fetch("env") == expected_validation_env
expected_validation_run = <<~BASH
  set -euo pipefail
  bash -euo pipefail -c "$PACKAGE_VALIDATE_COMMAND"
BASH
abort "caller validation execution drifted" unless validation.fetch("run") == expected_validation_run
abort "caller validation must run after package verification" unless steps.index(validation) == steps.index(package) + 1

implementation = steps.find { |step| step["name"] == "Check out workflow implementation" }
abort "missing workflow implementation checkout" unless implementation
expected_checkout = {
  "repository" => "${{ fromJSON(toJSON(job)).workflow_repository }}",
  "ref" => "${{ fromJSON(toJSON(job)).workflow_sha }}",
  "path" => ".harn/workflow-policy",
  "persist-credentials" => false
}
unless implementation.fetch("with") == expected_checkout
  abort "workflow implementation must be the exact called-workflow revision"
end
identity = steps.find { |step| step["name"] == "Require called-workflow identity" }
abort "missing called-workflow identity guard" unless identity
expected_identity_condition =
  "${{ fromJSON(toJSON(job)).workflow_repository == '' || fromJSON(toJSON(job)).workflow_sha == '' }}"
abort "workflow identity guard drifted" unless identity.fetch("if") == expected_identity_condition
expected_identity_error = <<~BASH
  echo "::error::harn-package.yml requires GitHub.com job.workflow_repository and job.workflow_sha; GitHub Enterprise Server is not supported"
  exit 2
BASH
abort "workflow identity diagnostic drifted" unless identity.fetch("run") == expected_identity_error

expected_action = "./.harn/workflow-policy/.github/actions/harn-package"
abort "package verification must use the co-versioned local action" unless package.fetch("uses") == expected_action
expected_policy = "./.harn/workflow-policy/.github/actions/harn-repo-policy"
abort "repository policy must use the co-versioned local action" unless policy.fetch("uses") == expected_policy

dependabot = steps.find { |step| step["name"] == "Check Dependabot config" }
abort "missing Dependabot delivery-policy step" unless dependabot
unless dependabot.fetch("if") == "${{ github.repository_owner == 'burin-labs' }}"
  abort "Dependabot delivery check must be scoped to Burin Labs callers"
end
expected_dependabot = "./.harn/workflow-policy/.github/actions/check-dependabot-config"
abort "Dependabot delivery check must use the co-versioned local action" unless dependabot.fetch("uses") == expected_dependabot
unless steps.index(dependabot) == steps.index(policy) + 1
  abort "Dependabot delivery check must follow repository projections"
end
unless steps.index(package) == steps.index(dependabot) + 1
  abort "package verification must follow the Dependabot delivery check"
end

strict = document.fetch(true).fetch("workflow_call").fetch("inputs").fetch("strict")
abort "strict package policy must be a boolean input" unless strict["type"] == "boolean"
abort "strict package policy must be the organization default" unless strict["default"] == true

forwarded_strict = package.fetch("with").fetch("strict")
expected_strict = "${{ inputs.strict }}"
abort "workflow must delegate strict policy to the package action" unless forwarded_strict == expected_strict
