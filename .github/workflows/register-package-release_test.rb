# frozen_string_literal: true

require "yaml"

workflow = YAML.safe_load(
  File.read(File.join(__dir__, "register-package-release.yml")),
  aliases: true
)
events = workflow.fetch(true)
unless events.keys == ["workflow_call"]
  abort "release registration must be callable only, so package repositories carry one line"
end

inputs = events.fetch("workflow_call").fetch("inputs")
defaults = inputs.transform_values { |input| input["default"] }
unless defaults.fetch("index-owner") == "burin-labs" && defaults.fetch("index-repository") == "harn-packages"
  abort "release registration must default to the org's package index"
end
abort "release registration must default to waiting" unless defaults.fetch("wait") == true

secrets = events.fetch("workflow_call").fetch("secrets")
unless secrets.values.all? { |secret| secret.fetch("required") == true }
  abort "release registration must require the app credentials it dispatches with"
end

job = workflow.fetch("jobs").fetch("register")
abort "release registration must stay on free hosted compute" unless job.fetch("runs-on") == "ubuntu-latest"
steps = job.fetch("steps")

token = steps.find { |step| step["name"] == "Mint the reconciler dispatch token" }
abort "release registration must mint a scoped app token" unless token
with = token.fetch("with")
unless with.fetch("permission-actions") == "write"
  abort "release registration must be able to dispatch the reconciler"
end
# Writing the index belongs to the reconciler, on its own token, in its own
# repository. A package repository that could write the index directly would
# reintroduce the N-copies-of-the-mechanism problem this workflow removes.
granted = with.keys.select { |key| key.start_with?("permission-") }
unless granted == ["permission-actions"]
  abort "release registration must request no authority beyond dispatch: #{granted.inspect}"
end

dispatch = steps.find { |step| step["name"] == "Ask the index to reconcile" }
run = dispatch.fetch("run")
abort "release registration must ask for a proposal" unless run.include?("-f mode=propose")
# Identifying the run by what appeared after the dispatch keeps two clocks out
# of the correlation. A timestamp comparison would silently pick the wrong run
# when the runner and the API disagree.
abort "release registration must correlate the run it started" unless run.include?("before=")
abort "release registration must fail when no run appears" unless run.include?("no new run appeared")

wait = steps.find { |step| step["name"] == "Wait for the index to agree" }
abort "release registration must be able to gate the release" unless wait.fetch("if") == "inputs.wait"
wait_run = wait.fetch("run")
unless wait_run.include?('[[ "$conclusion" != "success" ]]') && wait_run.include?("exit 1")
  abort "an unregistered release must fail the calling run, not pass quietly"
end
