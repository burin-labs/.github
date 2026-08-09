# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require "yaml"

module CiLatencyPolicy
  class Invalid < StandardError; end

  module_function

  def positive_integer(value, field)
    return value if value.is_a?(Integer) && value.positive?

    raise Invalid, "#{field} must be a positive integer"
  end

  def parse_policy(path)
    raw = JSON.parse(File.read(path))
    raise Invalid, "schema_version must be 1" unless raw["schema_version"] == 1

    %w[repository workflow event topology_epoch].each do |field|
      raise Invalid, "#{field} must be a non-empty string" unless raw[field].is_a?(String) && !raw[field].empty?
    end
    Time.iso8601(raw.fetch("topology_epoch"))

    sentinels = raw["full_run_jobs"]
    raise Invalid, "full_run_jobs must be a non-empty array" unless sentinels.is_a?(Array) && !sentinels.empty?
    sentinels.each_with_index do |sentinel, index|
      name = sentinel["name"]
      mode = sentinel.fetch("match", "exact")
      unless name.is_a?(String) && !name.empty? && %w[exact prefix].include?(mode)
        raise Invalid, "full_run_jobs[#{index}] requires name and exact|prefix match"
      end
    end

    slo = raw.fetch("slo")
    warning = positive_integer(slo["warning_ms"], "slo.warning_ms")
    target = positive_integer(slo["p90_ms"], "slo.p90_ms")
    hard_max = positive_integer(slo["hard_max_ms"], "slo.hard_max_ms")
    minimum = positive_integer(slo["min_samples"], "slo.min_samples")
    window = positive_integer(slo["window_samples"], "slo.window_samples")
    raise Invalid, "SLO thresholds must satisfy warning_ms < p90_ms < hard_max_ms" unless warning < target && target < hard_max
    raise Invalid, "slo.min_samples cannot exceed slo.window_samples" if minimum > window

    required = raw.fetch("required")
    aggregate = required["aggregate_job"]
    raise Invalid, "required.aggregate_job must be a non-empty string" unless aggregate.is_a?(String) && !aggregate.empty?
    allowance = positive_integer(required["critical_path_allowance_ms"], "required.critical_path_allowance_ms")
    jobs = required["jobs"]
    raise Invalid, "required.jobs must be a non-empty object" unless jobs.is_a?(Hash) && !jobs.empty?
    jobs.each do |id, job|
      raise Invalid, "required.jobs contains an empty job id" if id.empty?
      positive_integer(job["budget_ms"], "required.jobs.#{id}.budget_ms")
    end
    slowest = jobs.max_by { |_id, job| job.fetch("budget_ms") }
    if slowest.last.fetch("budget_ms") > allowance
      raise Invalid, "declared critical path #{slowest.last.fetch('budget_ms')}ms (#{slowest.first}) exceeds allowance #{allowance}ms"
    end

    raw
  rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
    raise Invalid, e.message
  end

  def workflow_needs(path, aggregate)
    workflow = YAML.safe_load(File.read(path), aliases: true)
    jobs = workflow.fetch("jobs")
    aggregate_job = jobs.fetch(aggregate) { raise Invalid, "aggregate job #{aggregate.inspect} is missing from workflow" }
    needs = aggregate_job.fetch("needs") { raise Invalid, "aggregate job #{aggregate.inspect} has no needs" }
    needs = [needs] if needs.is_a?(String)
    raise Invalid, "aggregate job #{aggregate.inspect} needs must be a string or array" unless needs.is_a?(Array)
    raise Invalid, "aggregate job #{aggregate.inspect} has an empty required set" if needs.empty?

    phantom = needs.reject { |id| jobs.key?(id) }
    raise Invalid, "aggregate job requires undefined jobs: #{phantom.join(', ')}" unless phantom.empty?

    needs
  rescue Psych::Exception, KeyError => e
    raise Invalid, e.message
  end

  def check(policy_path:, workflow_path:, baseline_path: nil, repository: nil)
    policy = parse_policy(policy_path)
    if repository && policy.fetch("repository") != repository
      raise Invalid, "policy repository #{policy.fetch('repository').inspect} does not match #{repository.inspect}"
    end
    required = policy.fetch("required")
    declared = required.fetch("jobs").keys.sort
    observed = workflow_needs(workflow_path, required.fetch("aggregate_job")).sort
    missing = observed - declared
    stale = declared - observed
    raise Invalid, "required jobs have no latency budget: #{missing.join(', ')}" unless missing.empty?
    raise Invalid, "latency budgets no longer feed the aggregate: #{stale.join(', ')}" unless stale.empty?

    if baseline_path && File.exist?(baseline_path)
      baseline = parse_policy(baseline_path)
      unless policy.fetch("repository") == baseline.fetch("repository")
        raise Invalid, "policy repository changed from #{baseline.fetch('repository').inspect} to #{policy.fetch('repository').inspect}"
      end
      unless policy.fetch("workflow") == baseline.fetch("workflow") && policy.fetch("event") == baseline.fetch("event")
        raise Invalid, "workflow or event changes require a new policy rather than weakening the existing contract"
      end
      %w[warning_ms p90_ms hard_max_ms].each do |field|
        old_value = baseline.dig("slo", field)
        new_value = policy.dig("slo", field)
        if new_value > old_value
          raise Invalid, "slo.#{field} may only decrease (#{old_value} -> #{new_value})"
        end
      end
      baseline_required = baseline.fetch("required")
      if required.fetch("critical_path_allowance_ms") > baseline_required.fetch("critical_path_allowance_ms")
        raise Invalid, "critical-path allowance may only decrease (#{baseline_required.fetch('critical_path_allowance_ms')} -> #{required.fetch('critical_path_allowance_ms')})"
      end
      baseline_required.fetch("jobs").each do |id, old_job|
        new_job = required.fetch("jobs")[id]
        next unless new_job && new_job.fetch("budget_ms") > old_job.fetch("budget_ms")

        raise Invalid, "job budget may only decrease: #{id} #{old_job.fetch('budget_ms')} -> #{new_job.fetch('budget_ms')}"
      end
    end

    policy
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on("--policy PATH") { |value| options[:policy_path] = value }
    parser.on("--workflow PATH") { |value| options[:workflow_path] = value }
    parser.on("--baseline PATH") { |value| options[:baseline_path] = value }
    parser.on("--repository OWNER/NAME") { |value| options[:repository] = value }
  end.parse!
  begin
    policy = CiLatencyPolicy.check(**options)
    puts "CI latency policy: OK (#{policy.dig('required', 'jobs').length} required jobs, #{policy.dig('required', 'critical_path_allowance_ms')}ms allowance)"
  rescue CiLatencyPolicy::Invalid => e
    warn "CI latency policy: #{e.message}"
    exit 1
  end
end
