# frozen_string_literal: true

require "yaml"

module HarnWorkflowPolicy
  class Violation < StandardError
    attr_reader :code, :path

    def initialize(path:, code:, message:)
      @path = path
      @code = code
      super(message)
    end

    def report
      "#{path}: [#{code}] #{message}"
    end
  end

  module_function

  def require_policy(condition, path, code, message)
    raise Violation.new(path: path, code: code, message: message) unless condition
  end

  def check!(path)
    document = YAML.safe_load(File.read(path), aliases: true)
    require_policy(document.is_a?(Hash), path, "workflow_mapping", "workflow must be a mapping")

    # Psych follows YAML 1.1 and may decode the unquoted GitHub key `on` as true.
    triggers = document["on"] || document[true]
    require_policy(
      triggers.is_a?(Hash) && triggers.key?("merge_group"),
      path,
      "merge_group_required",
      "workflow must declare merge_group",
    )

    jobs = document["jobs"]
    require_policy(jobs.is_a?(Hash), path, "jobs_required", "workflow must declare jobs")

    package_jobs = jobs.each_with_object([]) do |(name, job), matches|
      next unless job.is_a?(Hash)

      reusable = job["uses"]
      next unless reusable.is_a?(String)

      reference = reusable.match(
        %r{\Aburin-labs/\.github/\.github/workflows/harn-package\.yml@(?<sha>[0-9a-f]{40})\z},
      )
      next unless reference

      matches << {"name" => name, "sha" => reference["sha"]}
    end
    require_policy(
      !package_jobs.empty?,
      path,
      "canonical_package_missing",
      "no immutable call to the organization Harn package workflow",
    )
    require_policy(
      package_jobs.one?,
      path,
      "canonical_package_count",
      "declare exactly one canonical package workflow job",
    )

    package_reference = package_jobs.first
    package_name = package_reference.fetch("name")
    package_job = jobs.fetch(package_name)
    package_inputs = package_job.fetch("with", {})
    require_policy(
      package_inputs.is_a?(Hash),
      path,
      "package_inputs_mapping",
      "canonical package workflow inputs must be a mapping",
    )
    require_policy(
      !package_inputs.key?("strict") || package_inputs.fetch("strict") == true,
      path,
      "strict_required",
      "Burin Labs package CI strict input must be omitted or true",
    )

    status_jobs = jobs.each_with_object([]) do |(name, job), matches|
      matches << name if job.is_a?(Hash) && job["name"] == "CI status"
    end
    require_policy(
      status_jobs.one?,
      path,
      "status_job_count",
      "declare exactly one job named CI status",
    )

    status = jobs.fetch(status_jobs.first)
    needs = status["needs"]
    needs = [needs] if needs.is_a?(String)
    require_policy(
      needs.is_a?(Array) && needs.include?(package_name),
      path,
      "status_needs_package",
      "CI status must need the canonical package job",
    )
    require_policy(
      ["always()", "${{ always() }}"].include?(status["if"]),
      path,
      "status_always",
      "CI status must run with if: always()",
    )

    expected_status_action =
      "burin-labs/.github/.github/actions/require-successful-needs@#{package_reference.fetch("sha")}"
    status_steps = status.fetch("steps", [])
    status_actions = status_steps.select do |step|
      step.is_a?(Hash) && step["uses"].to_s.start_with?(
        "burin-labs/.github/.github/actions/require-successful-needs@",
      )
    end
    require_policy(
      status_actions.one? && status_actions.first["uses"] == expected_status_action,
      path,
      "status_action",
      "CI status must use the co-versioned successful-needs action",
    )
    require_policy(
      status_actions.first.fetch("with", {}) == {
        "results-json" => "${{ toJSON(needs.*.result) }}",
      },
      path,
      "status_results_projection",
      "CI status must pass every dependency result",
    )
    true
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    HarnWorkflowPolicy.check!(ARGV.fetch(0))
  rescue HarnWorkflowPolicy::Violation => error
    warn error.report
    exit 1
  end
end
