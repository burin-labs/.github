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

implementation = steps.find { |step| step["name"] == "Check out workflow implementation" }
abort "missing workflow implementation checkout" unless implementation
expected_checkout = {
  "repository" => "${{ fromJSON(toJSON(job)).workflow_repository }}",
  "ref" => "${{ fromJSON(toJSON(job)).workflow_sha }}",
  "path" => ".harn-policy",
  "persist-credentials" => false
}
unless implementation.fetch("with") == expected_checkout
  abort "workflow implementation must be the exact called-workflow revision"
end
expected_action = "./.harn-policy/.github/actions/harn-package"
abort "package verification must use the co-versioned local action" unless package.fetch("uses") == expected_action
expected_policy = "./.harn-policy/.github/actions/harn-repo-policy"
abort "repository policy must use the co-versioned local action" unless policy.fetch("uses") == expected_policy

strict = document.fetch(true).fetch("workflow_call").fetch("inputs").fetch("strict")
abort "strict package policy must be a boolean input" unless strict["type"] == "boolean"
abort "strict package policy must stay opt-in" unless strict["default"] == false

forwarded_strict = package.fetch("with").fetch("strict")
expected_strict = "${{ inputs.strict }}"
abort "workflow must delegate strict policy to the package action" unless forwarded_strict == expected_strict
