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
# The dispatch API returns nothing identifying, so the run has to be recognized
# after the fact. The reason is unique per calling run and the reconciler
# carries it in the run name, which is what makes the match exact.
unless dispatch.dig("env", "REASON").to_s.include?("github.run_id")
  abort "the dispatch reason must be unique per calling run, or it cannot identify a run"
end
abort "release registration must match the run by its name" unless run.include?("displayTitle")
# `--arg` belongs to jq, not to `gh run list`. Keeping the JSON producer and
# matcher as separate commands makes that authority boundary executable rather
# than depending on an unsupported gh option that fails every release late.
unless run.include?('jq -r --arg reason "$REASON"')
  abort "release registration must pass matcher variables to jq, not gh"
end
if run.match?(/gh run list[^|]*--arg/m)
  abort "release registration must not pass jq options to gh run list"
end
# The fallback exists for an index whose reconciler predates run naming. It is
# the old before-and-after diff, which is exact except against a concurrent
# caller, and that beats failing a release over an unadvanced pin.
abort "release registration must survive an index that does not name runs" unless run.include?("before=")
abort "release registration must fail when no run appears" unless run.include?("no new run appeared")

wait = steps.find { |step| step["name"] == "Wait for the index to agree" }
abort "release registration must be able to gate the release" unless wait.fetch("if") == "inputs.wait"
wait_run = wait.fetch("run")
unless wait_run.include?('[[ "$conclusion" != "success" ]]') && wait_run.include?("exit 1")
  abort "an unregistered release must fail the calling run, not pass quietly"
end
