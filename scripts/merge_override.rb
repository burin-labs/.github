# frozen_string_literal: true

# Decide and apply Burin Labs merge / CI override labels.
#
# Labels are a UX trigger only. Authority is re-checked here: the actor must be
# an organization admin, and the pull request head must live in the same
# repository (no fork overrides).

module MergeOverride
  LABELS = %w[bypass-ci bypass-merge-queue force-merge].freeze
  LABEL_PRECEDENCE = %w[force-merge bypass-merge-queue bypass-ci].freeze
  ACTIVE_RUN_STATUSES = %w[queued in_progress waiting pending].freeze
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

  def cancellation_required?(label)
    raise ArgumentError, "unknown override label: #{label.inspect}" unless known_label?(label)

    label == "bypass-ci" || label == "force-merge"
  end

  # The actions API is filtered by head SHA before this boundary. Measure the
  # current run's workflow_id through the same response, then exclude every run
  # of that dispatcher workflow. This keeps sibling override attempts alive.
  def select_competing_runs(current_run_id:, workflow_runs:)
    current = workflow_runs.find { |run| run.fetch("id") == current_run_id }
    raise RunSelectionError, "current run #{current_run_id} was absent from the measured run census" unless current

    workflow_id = current.fetch("workflow_id")
    active = workflow_runs.select { |run| ACTIVE_RUN_STATUSES.include?(run.fetch("status")) }
    override_runs, competing_runs = active.partition { |run| run.fetch("workflow_id") == workflow_id }
    {
      current_workflow_id: workflow_id,
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
    payload = JSON.parse(STDIN.read)
    puts JSON.generate(MergeOverride.resolve_request(
      attached_labels: payload.fetch("attached_labels"),
      events: payload.fetch("events")
    ))
  when "select-runs"
    payload = JSON.parse(STDIN.read)
    puts JSON.generate(MergeOverride.select_competing_runs(
      current_run_id: payload.fetch("current_run_id"),
      workflow_runs: payload.fetch("workflow_runs")
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
