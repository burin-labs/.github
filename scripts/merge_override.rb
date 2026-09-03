# frozen_string_literal: true

# Decide and apply Burin Labs merge / CI override labels.
#
# Labels are a UX trigger only. Authority is re-checked here: the actor must be
# an organization admin, and the pull request head must live in the same
# repository (no fork overrides).

module MergeOverride
  LABELS = %w[bypass-ci bypass-merge-queue force-merge].freeze
  LABEL_PRECEDENCE = %w[force-merge bypass-merge-queue bypass-ci].freeze
  ACTIVE_RUN_STATUSES = %w[requested queued in_progress waiting pending].freeze
  REQUIRED_CHECK = "CI status"

  module_function

  def known_label?(label)
    LABELS.include?(label)
  end

  # Resolve one serialized attempt from the labels that are attached when the
  # runner acquires the per-PR lock. GitHub keeps at most one pending member of
  # a concurrency group, so the surviving run must consume every label already
  # present. Issue events preserve the actor for each label even when the run
  # created by that particular event was replaced in the queue.
  def resolve_request(attached_labels:, events:)
    labels = LABELS.select { |label| attached_labels.include?(label) }
    return {label: nil, labels: [], actors: [], label_events: {}} if labels.empty?

    latest_events = labels.to_h do |label|
      latest = events
        .flatten
        .select { |event| event.dig("label", "name") == label }
        .max_by { |event| [event.fetch("created_at", ""), event.fetch("id", 0)] }
      unless latest&.fetch("event", nil) == "labeled" && latest.dig("actor", "login")
        raise RequestError, "could not identify the actor for attached label #{label.inspect}"
      end
      [label, latest]
    end

    {
      label: LABEL_PRECEDENCE.find { |candidate| labels.include?(candidate) },
      labels: labels,
      actors: latest_events.values.map { |event| event.dig("actor", "login") }.uniq.sort,
      label_events: latest_events.transform_values { |event| event.fetch("id") }
    }
  end

  def issue_events_from_pages(event_pages:)
    unless event_pages.is_a?(Array) && !event_pages.empty?
      raise RequestError, "issue-event census must contain at least one page"
    end
    events = event_pages.flat_map.with_index do |page, index|
      unless page.is_a?(Array)
        raise RequestError, "issue-event census page #{index + 1} was not an array"
      end
      page
    end
    ids = events.map.with_index do |event, index|
      unless event.is_a?(Hash) && event["id"].is_a?(Integer) && event["id"].positive?
        raise RequestError, "issue-event census item #{index + 1} omitted a positive event id"
      end
      event.fetch("id")
    end
    if ids.uniq.length != ids.length
      raise RequestError, "issue-event census contained a duplicate event id"
    end
    events
  end

  def cancellation_required?(label)
    raise ArgumentError, "unknown override label: #{label.inspect}" unless known_label?(label)

    label == "bypass-ci" || label == "force-merge"
  end

  # GitHub's paginated --slurp response is an array of page envelopes. Keep
  # that transport shape behind this seam so the workflow can stream the whole
  # response over stdin instead of encoding an unbounded document in argv.
  def workflow_run_census_from_pages(run_pages:)
    unless run_pages.is_a?(Array) && !run_pages.empty?
      raise RunSelectionError, "workflow-run census must contain at least one page envelope"
    end

    reported_totals = []
    workflow_runs = run_pages.flat_map.with_index do |page, index|
      unless page.is_a?(Hash) && page["workflow_runs"].is_a?(Array)
        raise RunSelectionError, "workflow-run census page #{index + 1} omitted workflow_runs"
      end
      reported_total = page["total_count"]
      unless reported_total.is_a?(Integer) && reported_total >= 0
        raise RunSelectionError, "workflow-run census page #{index + 1} omitted a non-negative total_count"
      end
      reported_totals << reported_total
      page.fetch("workflow_runs")
    end
    if reported_totals.uniq.length != 1
      raise RunSelectionError, "workflow-run census total_count changed during pagination"
    end
    reported_total = reported_totals.fetch(0)
    if workflow_runs.length != reported_total
      raise RunSelectionError,
            "workflow-run census measured #{workflow_runs.length} of #{reported_total} reported runs"
    end
    ids = workflow_runs.map { |run| run.is_a?(Hash) ? run["id"] : nil }
    unless ids.all? { |id| id.is_a?(Integer) && id.positive? }
      raise RunSelectionError, "workflow-run census contained a non-positive run id"
    end
    if ids.uniq.length != ids.length
      raise RunSelectionError, "workflow-run census contained a duplicate run id within one status query"
    end
    {
      workflow_runs: workflow_runs,
      page_count: run_pages.length,
      reported_total: reported_total
    }
  end

  # GitHub caps a head-SHA workflow-run query at 1,000 results. Querying each
  # active status separately prevents completed history from permanently
  # crowding live runs out of the cancellation census.
  def active_workflow_run_census_from_queries(status_pages:)
    unless status_pages.is_a?(Hash) && status_pages.keys.sort == ACTIVE_RUN_STATUSES.sort
      raise RunSelectionError, "active workflow-run census must measure every active status"
    end

    runs = ACTIVE_RUN_STATUSES.flat_map do |status|
      census = workflow_run_census_from_pages(run_pages: status_pages.fetch(status))
      census.fetch(:workflow_runs).each do |run|
        unless run.is_a?(Hash) && run["status"] == status
          raise RunSelectionError, "#{status} workflow-run census contained a different status"
        end
        unless run["workflow_id"].is_a?(Integer) && run["workflow_id"].positive?
          raise RunSelectionError, "#{status} workflow-run census omitted a positive workflow id"
        end
      end
      census.fetch(:workflow_runs)
    end
    runs_by_id = {}
    runs.each do |run|
      prior = runs_by_id[run.fetch("id")]
      if prior && prior.fetch("workflow_id") != run.fetch("workflow_id")
        raise RunSelectionError, "active workflow-run identity changed across status queries"
      end
      # A run can advance between sequential status queries. The later query is
      # the fresher observation; cancellation needs one stable id, not a false
      # corruption verdict for a legitimate requested -> queued transition.
      runs_by_id[run.fetch("id")] = run
    end
    {workflow_runs: runs_by_id.values, query_count: ACTIVE_RUN_STATUSES.length}
  end

  # The current run identity comes from its dedicated Actions endpoint. The
  # head-SHA census may legitimately be empty or may not yet contain the
  # current run, so deriving workflow_id from that eventually consistent list
  # makes absence indistinguishable from failure.
  def select_competing_runs(current_run_id:, current_workflow_id:, workflow_runs:)
    unless current_run_id.is_a?(Integer) && current_run_id.positive?
      raise RunSelectionError, "current run id must be a positive integer"
    end
    unless current_workflow_id.is_a?(Integer) && current_workflow_id.positive?
      raise RunSelectionError, "current workflow id must be a positive integer"
    end

    active = workflow_runs.select { |run| ACTIVE_RUN_STATUSES.include?(run.fetch("status")) }
    override_runs, competing_runs = active.partition do |run|
      run.fetch("workflow_id") == current_workflow_id
    end
    {
      current_workflow_id: current_workflow_id,
      pending_count: competing_runs.length,
      override_run_ids: override_runs.map { |run| run.fetch("id") }.reject { |id| id == current_run_id },
      competing_run_ids: competing_runs.map { |run| run.fetch("id") }
    }
  end

  def ci_state(check_runs)
    latest = check_runs
      .select { |check| check.fetch("name") == REQUIRED_CHECK }
      .max_by { |check| check["completed_at"] || check["started_at"] || "" }
    return "missing" unless latest
    return "in_flight" unless latest.fetch("status") == "completed"

    latest.fetch("conclusion") || "unknown"
  end

  def authorize!(
    org:,
    actor:,
    membership_role:,
    repository_permission:,
    head_repository:,
    base_repository:
  )
    errors = []
    # GITHUB_TOKEN often cannot read private org membership. Accept either an
    # organization-admin membership role or repository admin permission.
    admin = membership_role == "admin" || repository_permission == "admin"
    unless admin
      errors << "actor #{actor.inspect} is not an organization or repository admin of #{org}"
    end
    errors << "refusing override on a fork PR (head #{head_repository} != #{base_repository})" unless head_repository == base_repository
    raise AuthorizationError, errors.join("; ") unless errors.empty?
  end

  def plan(label:, ci_status_state:)
    raise ArgumentError, "unknown override label: #{label.inspect}" unless known_label?(label)

    case label
    when "bypass-ci"
      {
        cancel_workflows: true,
        publish_ci_status: true,
        merge: false,
        require_ci_green: false
      }
    when "bypass-merge-queue"
      unless ci_status_state == "success"
        reason = case ci_status_state
        when "in_flight"
          "#{REQUIRED_CHECK} is still in flight"
        when "missing"
          "no #{REQUIRED_CHECK.inspect} check exists"
        else
          "#{REQUIRED_CHECK} concluded #{ci_status_state.inspect}"
        end
        raise PlanError, "#{label} refused: #{reason}. " \
                         "Wait for a successful #{REQUIRED_CHECK}, then re-apply `#{label}`; " \
                         "use `force-merge` only when CI must also be overridden."
      end
      {
        cancel_workflows: false,
        publish_ci_status: false,
        merge: true,
        require_ci_green: true
      }
    when "force-merge"
      {
        cancel_workflows: true,
        publish_ci_status: true,
        merge: true,
        require_ci_green: false
      }
    end
  end

  def audit_body(label:, actor:, plan:)
    actions = []
    actions << "cancel in-progress workflows for the head SHA" if plan[:cancel_workflows]
    actions << "publish a successful #{REQUIRED_CHECK.inspect} check" if plan[:publish_ci_status]
    actions << "squash-merge directly (bypassing the merge queue and ruleset checks the release app may bypass)" if plan[:merge]
    <<~MARKDOWN.strip
      ### Merge override applied

      - Label: `#{label}`
      - Authorized actor: `@#{actor}` (organization or repository admin)
      - Actions: #{actions.empty? ? "none" : actions.join("; ")}

      Overrides are for CI incidents, merge-queue cost spikes, or rare fix-forward merges.
      Prefer the normal queue whenever it is cheap enough.
    MARKDOWN
  end

  def terminal_audit_body(status:, label:, consumed_labels:, removed_labels:, actors:, reason:, retry_action:, actions: nil)
    heading = {"applied" => "Applied", "refused" => "Refused", "errored" => "Errored"}.fetch(status)
    lines = [
      "### Merge override #{heading}",
      "",
      "- Selected label: `#{label}`",
      "- Requested by: #{actors.map { |actor| "@#{actor}" }.join(", ")}",
      "- Consumed labels: #{consumed_labels.map { |consumed| "`#{consumed}`" }.join(", ")}",
      "- Removed labels: #{removed_labels.empty? ? "none" : removed_labels.map { |removed| "`#{removed}`" }.join(", ")}",
      "- Outcome: #{reason}"
    ]
    lines << "- Actions: #{actions}" if actions && !actions.empty?
    lines << "- Retry: #{retry_action}" unless status == "applied"
    lines << ""
    lines << "The workflow re-checked organization or repository admin access and refused fork pull requests."
    lines.join("\n")
  end

  class AuthorizationError < StandardError; end
  class PlanError < StandardError; end
  class RequestError < StandardError; end
  class RunSelectionError < StandardError; end
end

if $PROGRAM_NAME == __FILE__
  require "json"

  command = ARGV.fetch(0)
  case command
  when "authorize"
    payload = JSON.parse(STDIN.read)
    MergeOverride.authorize!(
      org: payload.fetch("org"),
      actor: payload.fetch("actor"),
      membership_role: payload.fetch("membership_role"),
      repository_permission: payload.fetch("repository_permission"),
      head_repository: payload.fetch("head_repository"),
      base_repository: payload.fetch("base_repository")
    )
    puts "authorized"
  when "plan"
    payload = JSON.parse(STDIN.read)
    plan = MergeOverride.plan(
      label: payload.fetch("label"),
      ci_status_state: payload.fetch("ci_status_state")
    )
    puts JSON.generate(plan)
  when "resolve-request"
    attached_labels = JSON.parse(File.read(ARGV.fetch(1)))
    event_pages = JSON.parse(File.read(ARGV.fetch(2)))
    puts JSON.generate(MergeOverride.resolve_request(
      attached_labels: attached_labels,
      events: MergeOverride.issue_events_from_pages(event_pages: event_pages)
    ))
  when "select-runs"
    current_run_id = Integer(ARGV.fetch(1), 10)
    current_workflow_id = Integer(ARGV.fetch(2), 10)
    run_pages_dir = ARGV.fetch(3)
    status_pages = MergeOverride::ACTIVE_RUN_STATUSES.to_h do |status|
      [status, JSON.parse(File.read(File.join(run_pages_dir, "#{status}.json")))]
    end
    census = MergeOverride.active_workflow_run_census_from_queries(status_pages: status_pages)
    selection = MergeOverride.select_competing_runs(
      current_run_id: current_run_id,
      current_workflow_id: current_workflow_id,
      workflow_runs: census.fetch(:workflow_runs)
    )
    puts JSON.generate(selection.merge(
      measured_run_count: census.fetch(:workflow_runs).length,
      query_count: census.fetch(:query_count)
    ))
  when "ci-state"
    payload = JSON.parse(STDIN.read)
    puts MergeOverride.ci_state(payload.fetch("check_runs"))
  when "cancellation-required"
    payload = JSON.parse(STDIN.read)
    puts MergeOverride.cancellation_required?(payload.fetch("label"))
  when "terminal-audit-body"
    payload = JSON.parse(STDIN.read)
    puts MergeOverride.terminal_audit_body(
      status: payload.fetch("status"),
      label: payload.fetch("label"),
      consumed_labels: payload.fetch("consumed_labels"),
      removed_labels: payload.fetch("removed_labels"),
      actors: payload.fetch("actors"),
      reason: payload.fetch("reason"),
      retry_action: payload.fetch("retry_action"),
      actions: payload["actions"]
    )
  when "audit-body"
    payload = JSON.parse(STDIN.read)
    plan = if payload.key?("plan")
      raw = payload.fetch("plan")
      {
        cancel_workflows: raw.fetch("cancel_workflows"),
        publish_ci_status: raw.fetch("publish_ci_status"),
        merge: raw.fetch("merge"),
        require_ci_green: raw.fetch("require_ci_green")
      }
    else
      MergeOverride.plan(
        label: payload.fetch("label"),
        ci_status_state: payload.fetch("ci_status_state", "success")
      )
    end
    puts MergeOverride.audit_body(
      label: payload.fetch("label"),
      actor: payload.fetch("actor"),
      plan: plan
    )
  else
    warn "unknown command: #{command}"
    exit 2
  end
end
