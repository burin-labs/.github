#!/usr/bin/env ruby
# frozen_string_literal: true

# Reconcile dismissed Dependabot alerts against the waiver each repository
# checked in for them.
#
# Why this exists: GitHub only promises to auto-reopen alerts that one of its
# own auto-triage rules dismissed, and only when "the alert metadata or rule
# changed". A dismissal made by a human or by the REST API is never resurfaced,
# so an alert parked because upstream had shipped no patch stays parked forever
# -- including after the patch lands. Custom auto-triage rules, which do offer a
# "snooze until a patch is available" action, require GitHub Code Security on
# private repositories and have no API at all. This is the re-check that closes
# that gap.
#
# A waiver is a claim that an alert is not actionable *today*, recorded with the
# evidence that made it non-actionable. The audit re-derives that evidence and
# reopens the alert the moment the claim stops holding.

require "json"
require "net/http"
require "open3"
require "uri"

module DependabotWaivers
  SCHEMA_VERSION = 1
  DISMISSED_STATES = %w[dismissed auto_dismissed].freeze
  # GitHub's documented dismissal reasons. There is deliberately no reason
  # meaning "upstream shipped no patch", which is why a waiver carries its own
  # `why` prose and why this audit exists.
  REASONS = %w[fix_started inaccurate no_bandwidth not_used tolerable_risk].freeze
  SEVERITY_RANK = {"low" => 0, "medium" => 1, "high" => 2, "critical" => 3}.freeze
  WAIVER_PATH = ".github/dependabot-waivers.json"
  # Ecosystems whose upstream version caps the audit knows how to re-read.
  BLOCKER_REGISTRIES = {"cargo" => :crates, "pip" => :pypi, "npm" => :npm}.freeze

  class SchemaError < StandardError; end

  module_function

  # --- Pure policy ---------------------------------------------------------

  def validate!(document, repository: nil)
    errors = []
    unless document.is_a?(Hash)
      raise SchemaError, "waiver file must be a JSON object"
    end
    unless document["schema_version"] == SCHEMA_VERSION
      errors << "schema_version must be #{SCHEMA_VERSION}"
    end
    declared = document["repository"]
    errors << "repository must be a non-empty owner/name string" unless declared.is_a?(String) && declared.include?("/")
    if repository && declared != repository
      errors << "repository #{declared.inspect} does not match the repository the file lives in (#{repository})"
    end

    waivers = document["waivers"]
    unless waivers.is_a?(Array)
      raise SchemaError, ([*errors, "waivers must be an array"].join("; "))
    end

    numbers = waivers.map { |waiver| waiver.is_a?(Hash) ? waiver["alert_number"] : nil }
    if numbers.compact.uniq.length != numbers.length
      errors << "waivers must not repeat an alert_number"
    end

    waivers.each_with_index do |waiver, index|
      errors.concat(waiver_errors(waiver, index))
    end

    raise SchemaError, errors.join("; ") unless errors.empty?
    document
  end

  def waiver_errors(waiver, index)
    at = "waivers[#{index}]"
    return ["#{at} must be an object"] unless waiver.is_a?(Hash)

    errors = []
    errors << "#{at}.alert_number must be a positive integer" unless waiver["alert_number"].is_a?(Integer) && waiver["alert_number"].positive?
    errors << "#{at}.ghsa_id must look like GHSA-..." unless waiver["ghsa_id"].to_s.start_with?("GHSA-")
    %w[package ecosystem].each do |key|
      errors << "#{at}.#{key} must be a non-empty string" unless waiver[key].is_a?(String) && !waiver[key].empty?
    end
    unless REASONS.include?(waiver["dismissed_reason"])
      errors << "#{at}.dismissed_reason must be one of #{REASONS.join(", ")}"
    end
    # The prose is the part a human reads a year from now. An empty or
    # perfunctory `why` turns the registry back into an unexplained mute list,
    # which is the thing it exists to prevent.
    unless waiver["why"].is_a?(String) && waiver["why"].length >= 40
      errors << "#{at}.why must be at least 40 characters explaining why the alert is not actionable"
    end
    errors << "#{at}.review_by must be an ISO date" unless waiver["review_by"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    observed = waiver["observed"]
    if observed.is_a?(Hash)
      unless SEVERITY_RANK.key?(observed["severity"])
        errors << "#{at}.observed.severity must be one of #{SEVERITY_RANK.keys.join(", ")}"
      end
      unless [true, false].include?(observed["fix_available"])
        errors << "#{at}.observed.fix_available must be a boolean"
      end
      unless observed.key?("first_patched_version")
        errors << "#{at}.observed.first_patched_version must be present (null when upstream has shipped nothing)"
      end
      # A waiver that admits an installable fix exists is normally an unfiled
      # task, not a waiver. The one honest exception is a patch that is
      # published but unreachable in this dependency graph because a third
      # party caps the version -- and that has to be stated, with the reason
      # the obvious override does not work, or the exception becomes the
      # loophole that swallows every real task.
      if observed["fix_available"] == true && waiver["dismissed_reason"] != "fix_started"
        if observed["blocked_by"].nil?
          errors << "#{at} records an available fix, so it is actionable and must not be waived " \
                    "unless observed.blocked_by names the upstream constraint that prevents adopting it"
        else
          errors.concat(blocker_errors(observed["blocked_by"], "#{at}.observed.blocked_by"))
        end
      elsif observed["blocked_by"]
        errors << "#{at}.observed.blocked_by only means something when fix_available is true"
      end
    else
      errors << "#{at}.observed must be an object"
    end

    errors
  end

  def blocker_errors(blocker, at)
    return ["#{at} must be an object"] unless blocker.is_a?(Hash)

    errors = []
    # `constrains` is not always the vulnerable package. tui-textarea caps
    # ratatui, and ratatui is what drags in the vulnerable lru -- so the audit
    # has to be told which edge to re-read, or it silently reads a dependency
    # the blocker does not declare and reopens the alert every run.
    %w[package ecosystem version requirement constrains].each do |key|
      errors << "#{at}.#{key} must be a non-empty string" unless blocker[key].is_a?(String) && !blocker[key].empty?
    end
    unless BLOCKER_REGISTRIES.key?(blocker["ecosystem"])
      errors << "#{at}.ecosystem must be one of #{BLOCKER_REGISTRIES.keys.join(", ")} so the audit can re-check it"
    end
    # Nearly every capped dependency can technically be forced with an override
    # or a resolution pin. Whether that is safe is a judgement no schema can
    # make, so require it to be made in writing and reviewed.
    unless blocker["override_rejected"].is_a?(String) && blocker["override_rejected"].length >= 40
      errors << "#{at}.override_rejected must explain, in at least 40 characters, why forcing the fix past this constraint is not viable"
    end
    errors
  end

  # Decide what the audit should do about one waiver, given the live alert and
  # whether the advisory's claimed patch is actually installable today.
  #
  # Returns [verdict, detail]. Verdicts:
  #   :ok       -- still not actionable, leave dismissed
  #   :reopen   -- became actionable, put it back in front of a human
  #   :stale    -- the waiver no longer describes a dismissed alert, delete it
  #   :overdue  -- still not actionable but past its review date
  def reconcile(waiver:, alert:, fix_installable:, today:, blocker_state: nil)
    return [:stale, "alert #{waiver["alert_number"]} no longer exists"] if alert.nil?

    state = alert.dig("state")
    unless DISMISSED_STATES.include?(state)
      return [:stale, "alert is #{state}, not dismissed; the waiver no longer applies"]
    end

    live_ghsa = alert.dig("security_advisory", "ghsa_id")
    if live_ghsa != waiver["ghsa_id"]
      return [:reopen, "alert now points at #{live_ghsa}, not the waived #{waiver["ghsa_id"]}"]
    end

    observed = waiver.fetch("observed")
    live_severity = alert.dig("security_advisory", "severity")
    if SEVERITY_RANK.fetch(live_severity, -1) > SEVERITY_RANK.fetch(observed["severity"], -1)
      return [:reopen, "severity rose from #{observed["severity"]} to #{live_severity}"]
    end

    if fix_installable && !observed["fix_available"]
      patched = alert.dig("security_vulnerability", "first_patched_version", "identifier")
      return [:reopen, "an installable fix now exists (#{patched}); the waiver assumed none"]
    end

    # For a fix that exists but is capped out of reach, the thing to re-check is
    # the cap, not the patch. Any movement in what upstream publishes puts a
    # human back in the loop rather than trying to re-derive the semver maths.
    blocker = observed["blocked_by"]
    if blocker && blocker_state
      recorded = blocker.values_at("version", "requirement")
      live = blocker_state.values_at("version", "requirement")
      if live != recorded
        return [:reopen, "#{blocker["package"]} moved from #{recorded[0]} (#{recorded[1]}) " \
                         "to #{live[0]} (#{live[1]}); re-check whether the fix is reachable now"]
      end
    end

    return [:overdue, "review_by #{waiver["review_by"]} has passed"] if waiver["review_by"] < today

    [:ok, "no installable fix; severity unchanged at #{live_severity}"]
  end

  # Once a repository has a waiver registry it has opted into the policy, so a
  # dismissed alert with no waiver is a dismissal that recorded no reason and
  # carries no expiry -- invisible to the audit and unreadable a year from now.
  # Report it against the registry rather than letting it accumulate silently.
  def unwaived(alerts:, waivers:)
    waived = waivers.map { |waiver| waiver["alert_number"] }
    alerts.values.reject { |alert| waived.include?(alert["number"]) }.sort_by { |alert| alert["number"] }
  end

  def summarize(results)
    {
      "schema_version" => "burin.dependabot_waiver_audit.v1",
      "checked" => results.length,
      "reopened" => results.count { |r| r["verdict"] == "reopen" },
      "stale" => results.count { |r| r["verdict"] == "stale" },
      "overdue" => results.count { |r| r["verdict"] == "overdue" },
      "unwaived" => results.count { |r| r["verdict"] == "unwaived" },
      "ok" => results.count { |r| r["verdict"] == "ok" },
      "results" => results
    }
  end

  # --- IO ------------------------------------------------------------------

  # GitHub's `first_patched_version` is an advisory claim, not a resolvable
  # artifact. moby/moby publishes Docker 29.x under `docker-v29.*` git tags and
  # moved its Go module to `github.com/moby/moby/v2`, so the advisory can name
  # "29.3.1" while no such version of `github.com/docker/docker` exists on the
  # module proxy. Trusting the claim would reopen that alert every single run.
  def fix_installable?(ecosystem:, package:, version:)
    return false if version.nil? || version.to_s.empty?

    case ecosystem
    when "go" then go_module_version?(package, version)
    when "npm" then npm_version?(package, version)
    else true
    end
  end

  def go_module_version?(package, version)
    candidates = ["v#{version}", "v#{version}+incompatible"]
    candidates.any? { |candidate| head_ok?("https://proxy.golang.org/#{package.downcase}/@v/#{candidate}.info") }
  end

  def npm_version?(package, version)
    head_ok?("https://registry.npmjs.org/#{package}/#{version}")
  end

  # Read what the blocking package currently publishes: its newest release and
  # the requirement that release places on the dependency we cannot upgrade.
  # Returns nil on any failure, which leaves the waiver untouched -- a registry
  # outage must never read as "the block lifted".
  def blocker_state(package:, ecosystem:, dependency:)
    case BLOCKER_REGISTRIES[ecosystem]
    when :crates then crates_blocker(package, dependency)
    when :pypi then pypi_blocker(package, dependency)
    when :npm then npm_blocker(package, dependency)
    end
  rescue StandardError
    nil
  end

  def crates_blocker(package, dependency)
    crate = get_json("https://crates.io/api/v1/crates/#{package}")
    version = crate.dig("crate", "max_stable_version") or return nil
    deps = get_json("https://crates.io/api/v1/crates/#{package}/#{version}/dependencies").fetch("dependencies")
    requirement = deps.select { |dep| dep["crate_id"] == dependency }.map { |dep| dep["req"] }.sort.join(", ")
    {"version" => version, "requirement" => requirement}
  end

  def pypi_blocker(package, dependency)
    info = get_json("https://pypi.org/pypi/#{package}/json").fetch("info")
    # Keep only the plain runtime requirement. Extras and environment markers
    # come and go for unrelated reasons and would reopen the alert as noise.
    requirement = Array(info["requires_dist"])
      .select { |req| req.split(/[\s<>=!~;\[]/, 2).first == dependency && !req.include?(";") }
      .sort.join(", ")
    {"version" => info.fetch("version"), "requirement" => requirement}
  end

  def npm_blocker(package, dependency)
    packument = get_json("https://registry.npmjs.org/#{package}")
    version = packument.dig("dist-tags", "latest") or return nil
    requirement = packument.dig("versions", version, "dependencies", dependency).to_s
    {"version" => version, "requirement" => requirement}
  end

  def get_json(url)
    uri = URI.parse(url)
    request = Net::HTTP::Get.new(uri)
    # crates.io rejects requests without a descriptive User-Agent.
    request["User-Agent"] = "burin-labs-dependabot-waiver-audit"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
      http.request(request)
    end
    raise "#{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  end

  def head_ok?(url)
    uri = URI.parse(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    response.is_a?(Net::HTTPSuccess)
  rescue StandardError
    # A proxy outage must not be read as "a fix appeared". Fail closed toward
    # leaving the waiver alone; the next run re-checks.
    false
  end

  def gh_json(*args)
    out, err, status = Open3.capture3("gh", "api", *args)
    raise "gh api #{args.join(" ")} failed: #{err.strip}" unless status.success?
    JSON.parse(out)
  end

  def load_waivers(repository)
    raw = gh_json("repos/#{repository}/contents/#{WAIVER_PATH}", "--jq", ".content")
    validate!(JSON.parse(raw.delete("\n").unpack1("m")), repository: repository)
  rescue RuntimeError => error
    raise unless error.message.include?("Not Found")
    nil
  end

  def dismissed_alerts(repository)
    gh_json("repos/#{repository}/dependabot/alerts?state=dismissed&per_page=100", "--paginate")
      .to_h { |alert| [alert["number"], alert] }
  end

  def reopen!(repository, number)
    gh_json("--method", "PATCH", "repos/#{repository}/dependabot/alerts/#{number}", "-f", "state=open")
  end

  def audit(org:, today:, apply:)
    repositories = gh_json("orgs/#{org}/repos?per_page=100&type=all", "--paginate")
      .reject { |repo| repo["archived"] }
      .map { |repo| repo["full_name"] }
      .sort

    results = []
    repositories.each do |repository|
      document = load_waivers(repository)
      next if document.nil?

      alerts = dismissed_alerts(repository)
      unwaived(alerts: alerts, waivers: document.fetch("waivers")).each do |alert|
        results << {
          "repository" => repository,
          "alert_number" => alert["number"],
          "ghsa_id" => alert.dig("security_advisory", "ghsa_id"),
          "package" => alert.dig("security_vulnerability", "package", "name"),
          "verdict" => "unwaived",
          "detail" => "dismissed as #{alert["dismissed_reason"]} with no waiver recording why or when to revisit",
          "reopened" => false
        }
      end
      document.fetch("waivers").each do |waiver|
        alert = alerts[waiver["alert_number"]]
        installable = alert && fix_installable?(
          ecosystem: waiver["ecosystem"],
          package: waiver["package"],
          version: alert.dig("security_vulnerability", "first_patched_version", "identifier")
        )
        blocker = waiver.dig("observed", "blocked_by")
        live_blocker = blocker && blocker_state(
          package: blocker.fetch("package"),
          ecosystem: blocker.fetch("ecosystem"),
          dependency: blocker.fetch("constrains")
        )
        verdict, detail = reconcile(
          waiver: waiver, alert: alert, fix_installable: installable,
          today: today, blocker_state: live_blocker
        )
        reopen!(repository, waiver["alert_number"]) if verdict == :reopen && apply
        results << {
          "repository" => repository,
          "alert_number" => waiver["alert_number"],
          "ghsa_id" => waiver["ghsa_id"],
          "package" => waiver["package"],
          "verdict" => verdict.to_s,
          "detail" => detail,
          "reopened" => verdict == :reopen && apply
        }
      end
    end
    summarize(results)
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.shift
  case mode
  when "verify"
    path = ARGV.shift or abort "usage: #{$PROGRAM_NAME} verify <waivers.json> [owner/repo]"
    begin
      document = DependabotWaivers.validate!(JSON.parse(File.read(path)), repository: ARGV.shift)
      puts "dependabot waivers: ok (#{document.fetch("waivers").length} in #{document.fetch("repository")})"
    rescue DependabotWaivers::SchemaError, JSON::ParserError => error
      abort "dependabot waivers: #{error.message}"
    end
  when "audit"
    org = ARGV.include?("--org") ? ARGV[ARGV.index("--org") + 1] : "burin-labs"
    report = DependabotWaivers.audit(
      org: org,
      today: Time.now.utc.strftime("%Y-%m-%d"),
      apply: ARGV.include?("--apply")
    )
    puts JSON.pretty_generate(report)
    # A reopened alert is now visible in the alert queue, which is the whole
    # point, so it is not also a job failure. The rest are failures: they mean
    # the registry has drifted from reality and no longer says what is parked.
    exit 1 if %w[stale overdue unwaived].sum { |verdict| report.fetch(verdict) }.positive?
  else
    abort "usage: #{$PROGRAM_NAME} verify <waivers.json> [owner/repo] | audit --org <org> [--apply]"
  end
end
