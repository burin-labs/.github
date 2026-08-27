# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "time"

module CiLatencyObserver
  REPOSITORIES = [".github", "harn", "burin-code", "harn-cloud"].freeze
  RETRIES = 3

  module_function

  def report_error(report)
    return "report must be a JSON object" unless report.is_a?(Hash)
    return "schema_version must be 2" unless report["schema_version"] == 2
    return "policy.repository must be a non-empty string" unless report.dig("policy", "repository").is_a?(String) && !report.dig("policy", "repository").empty?
    return "qualifying_runs must be a list" unless report["qualifying_runs"].is_a?(Array)
    return "wall.count must be an integer" unless report.dig("wall", "count").is_a?(Integer)
    return "evaluation.status must be a non-empty string" unless report.dig("evaluation", "status").is_a?(String) && !report.dig("evaluation", "status").empty?
    return "evaluation.ok must be boolean" unless [true, false].include?(report.dig("evaluation", "ok"))
    return "evaluation.current must be an object" unless report.dig("evaluation", "current").is_a?(Hash)
    return "evaluation.previous must be an object" unless report.dig("evaluation", "previous").is_a?(Hash)
    return "policy.slo must be an object" unless report.dig("policy", "slo").is_a?(Hash)

    nil
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

  def classify(report, expected_run:, error: nil)
    repository = report.is_a?(Hash) ? report.dig("policy", "repository") : nil
    return observer_error(repository, error) if error

    invalid = report_error(report)
    return observer_error(repository, invalid) if invalid

    evaluation = report.fetch("evaluation")
    current = evaluation.fetch("current")
    previous = evaluation.fetch("previous")
    slo = report.dig("policy", "slo")
    qualifying_runs = report.fetch("qualifying_runs")
    if report.dig("wall", "count") != qualifying_runs.count
      return observer_error(repository, "wall.count does not match qualifying run count")
    end
    if qualifying_runs.empty? && evaluation.fetch("status") != "insufficient_samples"
      return observer_error(repository, "zero qualifying runs cannot carry a non-pending evaluation")
    end
    observed_run = qualifying_runs.first
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

    status = if evaluation.fetch("status") == "insufficient_samples"
      "insufficient_samples"
    elsif evaluation.fetch("ok")
      %w[warning single_window_p90_breach].include?(evaluation.fetch("status")) ? "policy_warning" : "pass"
    else
      "policy_breach"
    end

    breaches = []
    if status == "policy_breach"
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
      "breaches" => breaches,
      "freshness" => freshness
    }
  end

  def exit_status(receipts)
    receipts.all? { |receipt| %w[pass policy_warning].include?(receipt.fetch("status")) } ? 0 : 1
  end

  def summary(receipts)
    names_for = lambda do |status|
      receipts.select { |receipt| receipt.fetch("status") == status }
        .map { |receipt| receipt.fetch("repository") }
        .sort
    end
    warning_repositories = names_for.call("policy_warning")
    breaching_repositories = names_for.call("policy_breach")
    pending_repositories = names_for.call("insufficient_samples")
    stale_repositories = names_for.call("stale")
    observer_error_repositories = names_for.call("observer_error")
    {
      "schema_version" => 1,
      "repository_count" => receipts.count,
      "passing_count" => receipts.count { |receipt| receipt.fetch("status") == "pass" },
      "warning_count" => warning_repositories.count,
      "breach_count" => breaching_repositories.count,
      "pending_count" => pending_repositories.count,
      "stale_count" => stale_repositories.count,
      "observer_error_count" => observer_error_repositories.count,
      "warning_repositories" => warning_repositories,
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
      [stdout, stderr, status.success?]
    end

    def retry_capture(*args, accept:)
      last = ["", "command did not run", false]
      RETRIES.times do |attempt|
        last = capture(*args)
        return last if accept.call(last)
        sleep(@retry_delay * (attempt + 1)) if attempt < RETRIES - 1 && @retry_delay.positive?
      end
      last
    end

    def observe(repository)
      full_name = "burin-labs/#{repository}"
      policy_path = File.join(@policies, "#{repository}.json")
      report_path = File.join(@reports, "#{repository.delete_prefix(".")}.json")
      policy_stdout, policy_stderr, policy_ok = retry_capture(
        "gh", "api", "-H", "Accept: application/vnd.github.raw+json",
        "/repos/#{full_name}/contents/.github/ci-latency.json?ref=main",
        accept: ->((stdout, _stderr, success)) { success && valid_json?(stdout) }
      )
      unless policy_ok
        return write_error_report(report_path, full_name, "policy read failed: #{compact_error(policy_stderr)}")
      end
      File.write(policy_path, policy_stdout)
      policy = JSON.parse(policy_stdout)
      expected_run, freshness_error = latest_full_success(policy)
      if freshness_error
        return write_error_report(report_path, full_name, freshness_error)
      end

      report_stdout, report_stderr, report_ok = retry_capture(
        "harn", "run", "--no-sandbox", @harn_script, "--",
        "--policy", policy_path, "--limit", "100", "--json", "--check",
        accept: lambda do |(stdout, _stderr, _success)|
          parsed = parse_json(stdout)
          parsed && CiLatencyObserver.report_error(parsed).nil?
        end
      )
      unless report_ok
        return write_error_report(
          report_path,
          full_name,
          "measurement returned no valid report: #{compact_command_error(report_stdout, report_stderr)}"
        )
      end

      parsed = JSON.parse(report_stdout)
      receipt = CiLatencyObserver.classify(parsed, expected_run: expected_run)
      parsed["observer"] = receipt
      parsed["observer_result"] = %w[stale observer_error].include?(receipt.fetch("status")) ? "fail" : "pass"
      parsed["policy_result"] = case receipt.fetch("status")
      when "pass" then "pass"
      when "policy_warning" then "warning"
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
      runs_stdout, runs_stderr, runs_ok = retry_capture(
        "gh", "api",
        "/repos/#{repository}/actions/workflows/#{workflow}/runs?event=#{event}&status=completed&per_page=20",
        accept: ->((stdout, _stderr, success)) { success && valid_json?(stdout) }
      )
      return [nil, "freshness read failed: #{compact_error(runs_stderr)}"] unless runs_ok

      runs = JSON.parse(runs_stdout).fetch("workflow_runs", [])
        .select do |run|
          run["conclusion"] == "success" && Time.iso8601(run.fetch("created_at")) >= epoch
        end
      runs.each do |run|
        jobs_stdout, jobs_stderr, jobs_ok = retry_capture(
          "gh", "api", "/repos/#{repository}/actions/runs/#{run.fetch("id")}/jobs?per_page=100",
          accept: ->((stdout, _stderr, success)) { success && valid_json?(stdout) }
        )
        return [nil, "freshness job read failed: #{compact_error(jobs_stderr)}"] unless jobs_ok
        jobs = JSON.parse(jobs_stdout).fetch("jobs", [])
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
