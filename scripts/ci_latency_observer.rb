# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "time"
require_relative "../.github/actions/ci-latency-policy/ci_latency_baseline"

module CiLatencyObserver
  REPOSITORIES = [".github", "harn", "burin-code", "harn-cloud"].freeze
  PRODUCER_STATUS_OK = {
    "healthy" => true,
    "warning" => true,
    "single_window_p90_breach" => true,
    "sustained_p90_breach" => false,
    "hard_max_breach" => false,
    "insufficient_samples" => false
  }.freeze
  RETRIES = 3
  CommandResult = Struct.new(:stdout, :stderr, :process_ok, :accepted, keyword_init: true)

  module_function

  def report_error(report)
    return "report must be a JSON object" unless report.is_a?(Hash)
    return "schema_version must be 2" unless report["schema_version"] == 2
    return "policy.repository must be a non-empty string" unless report.dig("policy", "repository").is_a?(String) && !report.dig("policy", "repository").empty?
    return "qualifying_runs must be a list" unless report["qualifying_runs"].is_a?(Array)
    return "wall.count must be an integer" unless report.dig("wall", "count").is_a?(Integer)
    status = report.dig("evaluation", "status")
    return "evaluation.status is not a recognized producer status" unless PRODUCER_STATUS_OK.key?(status)
    return "evaluation.ok must be boolean" unless [true, false].include?(report.dig("evaluation", "ok"))
    return "evaluation.ok contradicts evaluation.status #{status}" unless report.dig("evaluation", "ok") == PRODUCER_STATUS_OK.fetch(status)
    return "evaluation.current must be an object" unless report.dig("evaluation", "current").is_a?(Hash)
    return "evaluation.previous must be an object" unless report.dig("evaluation", "previous").is_a?(Hash)
    return "policy.slo must be an object" unless report.dig("policy", "slo").is_a?(Hash)
    %w[current previous].each do |window|
      %w[count p90_ms max_ms].each do |field|
        value = report.dig("evaluation", window, field)
        return "evaluation.#{window}.#{field} must be a non-negative integer" unless value.is_a?(Integer) && value >= 0
      end
    end
    %w[warning_ms p90_ms hard_max_ms min_samples window_samples].each do |field|
      value = report.dig("policy", "slo", field)
      return "policy.slo.#{field} must be a positive integer" unless value.is_a?(Integer) && value.positive?
    end
    slo = report.dig("policy", "slo")
    unless slo.fetch("warning_ms") < slo.fetch("p90_ms") && slo.fetch("p90_ms") < slo.fetch("hard_max_ms")
      return "policy.slo thresholds are not ordered"
    end
    return "policy.slo.min_samples exceeds window_samples" if slo.fetch("min_samples") > slo.fetch("window_samples")
    unless report.fetch("qualifying_runs").all? { |run| valid_qualifying_run?(run) }
      return "qualifying_runs entries require an integer id and ISO-8601 created_at"
    end

    nil
  end

  def valid_qualifying_run?(run)
    return false unless run.is_a?(Hash) && run["id"].is_a?(Integer) && run["created_at"].is_a?(String)

    Time.iso8601(run.fetch("created_at"))
    true
  rescue ArgumentError
    false
  end

  def run_order_key(run)
    [Time.iso8601(run.fetch("created_at")), run.fetch("id")]
  end

  def newest_run(runs)
    runs.sort_by { |run| run_order_key(run) }.reverse.first
  end

  def target_debts(current, slo)
    [
      ["evaluation.current.p90_ms", "p90_ms"],
      ["evaluation.current.max_ms", "hard_max_ms"]
    ].each_with_object([]) do |(metric, threshold), debts|
      observed_ms = current.fetch(metric.split(".").last)
      target_ms = slo.fetch(threshold)
      next if observed_ms < target_ms

      debts << {
        "metric" => metric,
        "observed_ms" => observed_ms,
        "target_ms" => target_ms,
        "gap_ms" => observed_ms - target_ms,
        "sample_count" => current.fetch("count", 0)
      }
    end
  end

  def regression_breaches(current, previous, baseline, qualifying_runs, window_samples)
    breaches = []
    sampled_at = Time.iso8601(baseline.fetch("sampled_at"))
    post_baseline_count = qualifying_runs.count do |run|
      Time.iso8601(run.fetch("created_at")) > sampled_at
    end
    required_post_baseline = window_samples * 2
    p90_limit = baseline.fetch("p90_regression_limit_ms")
    if post_baseline_count >= required_post_baseline &&
        current.fetch("p90_ms") >= p90_limit && previous.fetch("p90_ms") >= p90_limit
      [current, previous].each_with_index do |window, index|
        breaches << {
          "metric" => "evaluation.#{index.zero? ? 'current' : 'previous'}.p90_ms",
          "observed_ms" => window.fetch("p90_ms"),
          "threshold_ms" => p90_limit,
          "sample_count" => window.fetch("count", 0)
        }
      end
    end

    max_limit = baseline.fetch("max_regression_limit_ms")
    if current.fetch("max_ms") >= max_limit
      breaches << {
        "metric" => "evaluation.current.max_ms",
        "observed_ms" => current.fetch("max_ms"),
        "threshold_ms" => max_limit,
        "sample_count" => current.fetch("count", 0)
      }
    end
    [
      breaches,
      {
        "post_baseline_sample_count" => post_baseline_count,
        "required_sample_count" => required_post_baseline,
        "p90_status" => post_baseline_count >= required_post_baseline ? "enforcing" : "warming"
      }
    ]
  end

  def observer_error(repository, message)
    {
      "repository" => repository || "unknown",
      "status" => "observer_error",
      "evaluation_status" => "observer_error",
      "sample_count" => 0,
      "breaches" => [],
      "error" => message,
      "freshness" => {"status" => "unknown"}
    }
  end

  def classify(report, expected_run:, policy: nil, error: nil)
    repository = report.is_a?(Hash) ? report.dig("policy", "repository") : nil
    return observer_error(repository, error) if error

    invalid = report_error(report)
    return observer_error(repository, invalid) if invalid

    authoritative_policy = policy || report.fetch("policy")
    policy_mismatch = policy && %w[repository workflow event topology_epoch slo full_run_jobs].any? do |field|
      report.dig("policy", field) != policy[field]
    end
    return observer_error(repository, "measurement policy projection does not match the fetched policy") if policy_mismatch

    evaluation = report.fetch("evaluation")
    current = evaluation.fetch("current")
    previous = evaluation.fetch("previous")
    slo = authoritative_policy.fetch("slo")
    qualifying_runs = report.fetch("qualifying_runs")
    if report.dig("wall", "count") != qualifying_runs.count
      return observer_error(repository, "wall.count does not match qualifying run count")
    end
    if qualifying_runs.empty? && evaluation.fetch("status") != "insufficient_samples"
      return observer_error(repository, "zero qualifying runs cannot carry a non-pending evaluation")
    end
    observed_run = newest_run(qualifying_runs)
    freshness = {
      "status" => observed_run ? "current" : "absent",
      "expected_run_id" => expected_run&.fetch("id", nil),
      "expected_created_at" => expected_run&.fetch("created_at", nil),
      "observed_run_id" => observed_run&.fetch("id", nil),
      "observed_created_at" => observed_run&.fetch("created_at", nil)
    }

    if expected_run.nil? && observed_run
      freshness["status"] = "unknown"
      return {
        "repository" => repository,
        "status" => "observer_error",
        "evaluation_status" => evaluation.fetch("status"),
        "sample_count" => report.dig("wall", "count"),
        "current_window" => current,
        "previous_window" => previous,
        "thresholds" => slo,
        "breaches" => [],
        "error" => "independent freshness probe found no successful full-coverage run",
        "freshness" => freshness
      }
    end

    if expected_run && freshness["observed_run_id"] != freshness["expected_run_id"]
      freshness["status"] = "stale"
      return {
        "repository" => repository,
        "status" => "stale",
        "evaluation_status" => evaluation.fetch("status"),
        "sample_count" => report.dig("wall", "count"),
        "current_window" => current,
        "previous_window" => previous,
        "thresholds" => slo,
        "breaches" => [],
        "error" => "latest successful full-coverage run is absent from the measured window",
        "freshness" => freshness
      }
    end

    baseline = nil
    if authoritative_policy.key?("observed_baseline")
      begin
        baseline = CiLatencyBaseline.validate(authoritative_policy)
      rescue CiLatencyBaseline::Invalid => e
        receipt = observer_error(repository, "observed baseline is invalid: #{e.message}")
        receipt["sample_count"] = report.dig("wall", "count")
        receipt["freshness"] = freshness
        return receipt
      end
    end

    debt = []
    breaches = []
    regression_window = nil
    if baseline
      debt = target_debts(current, slo)
      breaches, regression_window = regression_breaches(
        current,
        previous,
        baseline,
        qualifying_runs,
        slo.fetch("window_samples")
      )
      status = if evaluation.fetch("status") == "insufficient_samples"
        "insufficient_samples"
      elsif breaches.any?
        "policy_breach"
      elsif debt.any?
        "target_debt"
      elsif %w[warning single_window_p90_breach].include?(evaluation.fetch("status"))
        "policy_warning"
      else
        "pass"
      end
    else
      status = if evaluation.fetch("status") == "insufficient_samples"
        "insufficient_samples"
      elsif evaluation.fetch("ok")
        %w[warning single_window_p90_breach].include?(evaluation.fetch("status")) ? "policy_warning" : "pass"
      else
        "policy_breach"
      end
    end

    if status == "policy_breach" && baseline.nil?
      p90_threshold = slo.fetch("p90_ms")
      hard_max_threshold = slo.fetch("hard_max_ms")
      current_count = current.fetch("count", 0)
      previous_count = previous.fetch("count", 0)

      if current.fetch("p90_ms", 0) >= p90_threshold
        breaches << {
          "metric" => "evaluation.current.p90_ms",
          "observed_ms" => current.fetch("p90_ms"),
          "threshold_ms" => p90_threshold,
          "sample_count" => current_count
        }
      end
      sustained = evaluation["sustained_breach"] == true || evaluation.fetch("status") == "sustained_p90_breach"
      if previous.fetch("p90_ms", 0) >= p90_threshold && sustained
        breaches << {
          "metric" => "evaluation.previous.p90_ms",
          "observed_ms" => previous.fetch("p90_ms"),
          "threshold_ms" => p90_threshold,
          "sample_count" => previous_count
        }
      end
      if current.fetch("max_ms", 0) >= hard_max_threshold
        breaches << {
          "metric" => "evaluation.current.max_ms",
          "observed_ms" => current.fetch("max_ms"),
          "threshold_ms" => hard_max_threshold,
          "sample_count" => current_count
        }
      end
    end

    {
      "repository" => repository,
      "status" => status,
      "evaluation_status" => evaluation.fetch("status"),
      "sample_count" => report.dig("wall", "count"),
      "current_window" => current,
      "previous_window" => previous,
      "thresholds" => slo,
      "observed_baseline" => baseline,
      "regression_window" => regression_window,
      "breaches" => breaches,
      "target_debt" => debt,
      "freshness" => freshness
    }
  end

  def exit_status(receipts)
    receipts.all? { |receipt| %w[pass policy_warning target_debt].include?(receipt.fetch("status")) } ? 0 : 1
  end

  def summary(receipts)
    names_for = lambda do |status|
      receipts.select { |receipt| receipt.fetch("status") == status }
        .map { |receipt| receipt.fetch("repository") }
        .sort
    end
    warning_repositories = names_for.call("policy_warning")
    target_debt_repositories = names_for.call("target_debt")
    breaching_repositories = names_for.call("policy_breach")
    pending_repositories = names_for.call("insufficient_samples")
    stale_repositories = names_for.call("stale")
    observer_error_repositories = names_for.call("observer_error")
    {
      "schema_version" => 2,
      "repository_count" => receipts.count,
      "passing_count" => receipts.count { |receipt| receipt.fetch("status") == "pass" },
      "warning_count" => warning_repositories.count,
      "target_debt_count" => target_debt_repositories.count,
      "breach_count" => breaching_repositories.count,
      "pending_count" => pending_repositories.count,
      "stale_count" => stale_repositories.count,
      "observer_error_count" => observer_error_repositories.count,
      "warning_repositories" => warning_repositories,
      "target_debt_repositories" => target_debt_repositories,
      "breaching_repositories" => breaching_repositories,
      "pending_repositories" => pending_repositories,
      "stale_repositories" => stale_repositories,
      "observer_error_repositories" => observer_error_repositories,
      "repositories" => receipts
    }
  end

  def markdown(summary_report)
    lines = [
      "## End-to-end CI latency",
      "",
      "Observer failures, stale measurements, insufficient samples, and policy breaches are separate states.",
      "",
      "| Repository | State | Samples | Exact evidence |",
      "| --- | --- | ---: | --- |"
    ]
    summary_report.fetch("repositories").each do |receipt|
      evidence = if receipt.fetch("breaches").any?
        receipt.fetch("breaches").map do |breach|
          "#{breach.fetch("metric")}=#{breach.fetch("observed_ms")}ms >= #{breach.fetch("threshold_ms")}ms (n=#{breach.fetch("sample_count")})"
        end.join("; ")
      elsif receipt.fetch("target_debt", []).any?
        receipt.fetch("target_debt").map do |debt|
          "#{debt.fetch("metric")}=#{debt.fetch("observed_ms")}ms, target #{debt.fetch("target_ms")}ms, gap +#{debt.fetch("gap_ms")}ms (n=#{debt.fetch("sample_count")})"
        end.join("; ")
      elsif receipt.fetch("status") == "stale"
        "expected run #{receipt.dig("freshness", "expected_run_id")}, observed #{receipt.dig("freshness", "observed_run_id") || "none"}"
      elsif receipt["error"]
        receipt.fetch("error")
      else
        receipt.fetch("evaluation_status")
      end
      safe_evidence = evidence.to_s.gsub("|", "\\|").gsub(/\s+/, " ").strip
      lines << "| `#{receipt.fetch("repository")}` | `#{receipt.fetch("status")}` | #{receipt.fetch("sample_count")} | #{safe_evidence} |"
    end
    lines << ""
    lines << "Target debt: #{summary_report.fetch("target_debt_repositories").join(", ").then { |value| value.empty? ? "none" : value }}"
    lines << "Failing: #{summary_report.fetch("breaching_repositories").join(", ").then { |value| value.empty? ? "none" : value }}"
    lines << "Pending: #{summary_report.fetch("pending_repositories").join(", ").then { |value| value.empty? ? "none" : value }}"
    lines << "Stale: #{summary_report.fetch("stale_repositories").join(", ").then { |value| value.empty? ? "none" : value }}"
    lines << "Observer errors: #{summary_report.fetch("observer_error_repositories").join(", ").then { |value| value.empty? ? "none" : value }}"
    lines.join("\n") + "\n"
  end

  class Runner
    def initialize(reports:, policies:, harn_script:, summary_path:, retry_delay: 5)
      @reports = reports
      @policies = policies
      @harn_script = harn_script
      @summary_path = summary_path
      @retry_delay = retry_delay
    end

    def run
      FileUtils.mkdir_p(@reports)
      FileUtils.mkdir_p(@policies)
      observations = {}
      threads = REPOSITORIES.map do |repository|
        Thread.new { observations[repository] = observe(repository) }
      end
      threads.each(&:join)
      receipts = REPOSITORIES.map { |repository| observations.fetch(repository).fetch("receipt") }
      report = CiLatencyObserver.summary(receipts)
      File.write(File.join(@reports, "org-summary.json"), JSON.pretty_generate(report) + "\n")
      File.open(@summary_path, "a") { |file| file.write(CiLatencyObserver.markdown(report)) }
      annotate(report)
      CiLatencyObserver.exit_status(receipts)
    end

    private

    def capture(*args)
      stdout, stderr, status = Open3.capture3(*args)
      CommandResult.new(
        stdout: stdout,
        stderr: stderr,
        process_ok: status.success?,
        accepted: false
      )
    end

    def retry_capture(*args, accept:)
      last = CommandResult.new(
        stdout: "",
        stderr: "command did not run",
        process_ok: false,
        accepted: false
      )
      RETRIES.times do |attempt|
        last = capture(*args)
        last.accepted = accept.call(last)
        return last if last.accepted
        sleep(@retry_delay * (attempt + 1)) if attempt < RETRIES - 1 && @retry_delay.positive?
      end
      last
    end

    def observe(repository)
      full_name = "burin-labs/#{repository}"
      policy_path = File.join(@policies, "#{repository}.json")
      report_path = File.join(@reports, "#{repository.delete_prefix(".")}.json")
      policy_result = retry_capture(
        "gh", "api", "-H", "Accept: application/vnd.github.raw+json",
        "/repos/#{full_name}/contents/.github/ci-latency.json?ref=main",
        accept: ->(result) { result.process_ok && valid_json?(result.stdout) }
      )
      unless policy_result.accepted
        return write_error_report(report_path, full_name, "policy read failed: #{compact_error(policy_result.stderr)}")
      end
      File.write(policy_path, policy_result.stdout)
      policy = JSON.parse(policy_result.stdout)
      expected_run, freshness_error = latest_full_success(policy)
      if freshness_error
        return write_error_report(report_path, full_name, freshness_error)
      end

      report_result = retry_capture(
        "harn", "run", "--no-sandbox", @harn_script, "--",
        "--policy", policy_path, "--limit", "100", "--json", "--check",
        accept: lambda do |result|
          parsed = parse_json(result.stdout)
          parsed && CiLatencyObserver.report_error(parsed).nil?
        end
      )
      unless report_result.accepted
        return write_error_report(
          report_path,
          full_name,
          "measurement returned no valid report: #{compact_command_error(report_result.stdout, report_result.stderr)}"
        )
      end

      parsed = JSON.parse(report_result.stdout)
      receipt = CiLatencyObserver.classify(parsed, expected_run: expected_run, policy: policy)
      parsed["observer"] = receipt
      parsed["observer_result"] = %w[stale observer_error].include?(receipt.fetch("status")) ? "fail" : "pass"
      parsed["policy_result"] = case receipt.fetch("status")
      when "pass" then "pass"
      when "policy_warning" then "warning"
      when "target_debt" then "target_debt"
      when "policy_breach" then "breach"
      when "insufficient_samples" then "pending"
      else "unknown"
      end
      File.write(report_path, JSON.pretty_generate(parsed) + "\n")
      {"report" => parsed, "receipt" => receipt}
    rescue StandardError => error
      write_error_report(report_path, full_name, "observer exception: #{error.message}")
    end

    def latest_full_success(policy)
      repository = policy.fetch("repository")
      workflow = policy.fetch("workflow")
      event = policy.fetch("event")
      epoch = Time.iso8601(policy.fetch("topology_epoch"))
      runs_result = retry_capture(
        "gh", "api",
        "/repos/#{repository}/actions/workflows/#{workflow}/runs?event=#{event}&status=completed&per_page=20",
        accept: ->(result) { result.process_ok && valid_json?(result.stdout) }
      )
      return [nil, "freshness read failed: #{compact_error(runs_result.stderr)}"] unless runs_result.accepted

      runs = JSON.parse(runs_result.stdout).fetch("workflow_runs", [])
        .select do |run|
          run["conclusion"] == "success" && Time.iso8601(run.fetch("created_at")) >= epoch
        end
        .sort_by { |run| CiLatencyObserver.run_order_key(run) }
        .reverse
      runs.each do |run|
        jobs_result = retry_capture(
          "gh", "api", "/repos/#{repository}/actions/runs/#{run.fetch("id")}/jobs?per_page=100",
          accept: ->(result) { result.process_ok && valid_json?(result.stdout) }
        )
        return [nil, "freshness job read failed: #{compact_error(jobs_result.stderr)}"] unless jobs_result.accepted
        jobs = JSON.parse(jobs_result.stdout).fetch("jobs", [])
        if full_coverage?(jobs, policy.fetch("full_run_jobs"))
          return [{"id" => run.fetch("id"), "created_at" => run.fetch("created_at")}, nil]
        end
      end
      [nil, nil]
    rescue JSON::ParserError, KeyError, ArgumentError => error
      [nil, "freshness receipt invalid: #{error.message}"]
    end

    def full_coverage?(jobs, sentinels)
      sentinels.all? do |sentinel|
        jobs.any? do |job|
          next false unless job["conclusion"] == "success"
          sentinel.fetch("match") == "prefix" ? job.fetch("name", "").start_with?(sentinel.fetch("name")) : job["name"] == sentinel.fetch("name")
        end
      end
    end

    def write_error_report(path, repository, message)
      receipt = CiLatencyObserver.observer_error(repository, message)
      report = {
        "schema_version" => 2,
        "policy" => {"repository" => repository},
        "evaluation" => {"status" => "observer_error", "ok" => false},
        "wall" => {"count" => 0, "p50_ms" => 0, "p90_ms" => 0, "max_ms" => 0},
        "observer" => receipt,
        "observer_result" => "fail",
        "policy_result" => "unknown"
      }
      File.write(path, JSON.pretty_generate(report) + "\n")
      {"report" => report, "receipt" => receipt}
    end

    def parse_json(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    def valid_json?(text)
      !parse_json(text).nil?
    end

    def compact_error(stderr)
      text = stderr.to_s.strip.lines.last(3).join(" ").strip
      text.empty? ? "no diagnostic" : text
    end

    def compact_command_error(stdout, stderr)
      parts = []
      stdout_text = stdout.to_s.strip.lines.last(3).join(" ").strip
      stderr_text = stderr.to_s.strip.lines.last(3).join(" ").strip
      parts << "stdout=#{stdout_text}" unless stdout_text.empty?
      parts << "stderr=#{stderr_text}" unless stderr_text.empty?
      parts.empty? ? "no diagnostic" : parts.join("; ")
    end

    def annotate(report)
      report.fetch("repositories").each do |receipt|
        next if %w[pass policy_warning].include?(receipt.fetch("status"))
        if receipt.fetch("status") == "target_debt"
          evidence = receipt.fetch("target_debt").map do |debt|
            "#{debt.fetch("metric")}=#{debt.fetch("observed_ms")}ms target=#{debt.fetch("target_ms")}ms gap=+#{debt.fetch("gap_ms")}ms n=#{debt.fetch("sample_count")}"
          end.join("; ")
          message = evidence.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
          puts "::warning title=CI latency target debt #{receipt.fetch("repository")}::#{message}"
          next
        end
        evidence = receipt.fetch("breaches").map do |breach|
          "#{breach.fetch("metric")}=#{breach.fetch("observed_ms")}ms threshold=#{breach.fetch("threshold_ms")}ms n=#{breach.fetch("sample_count")}"
        end.join("; ")
        evidence = receipt["error"] if evidence.empty?
        evidence = receipt.fetch("evaluation_status") if evidence.to_s.empty?
        message = evidence.to_s.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
        puts "::error title=CI latency #{receipt.fetch("status")} #{receipt.fetch("repository")}::#{message}"
      end
    end
  end

  def cli(argv)
    options = {retry_delay: ENV.fetch("CI_LATENCY_RETRY_DELAY_SECONDS", "5").to_i}
    OptionParser.new do |parser|
      parser.on("--reports PATH") { |value| options[:reports] = value }
      parser.on("--policies PATH") { |value| options[:policies] = value }
      parser.on("--harn-script PATH") { |value| options[:harn_script] = value }
      parser.on("--summary-path PATH") { |value| options[:summary_path] = value }
    end.parse!(argv)
    required = %i[reports policies harn_script summary_path]
    missing = required.reject { |key| options[key] }
    abort "missing required options: #{missing.join(", ")}" unless missing.empty?
    Runner.new(**options).run
  end
end

exit CiLatencyObserver.cli(ARGV) if $PROGRAM_NAME == __FILE__
