# frozen_string_literal: true

# Decide and apply Burin Labs merge / CI override labels.
#
# Labels are a UX trigger only. Authority is re-checked here: the actor must be
# an organization admin, and the pull request head must live in the same
# repository (no fork overrides).

module MergeOverride
  LABELS = %w[bypass-ci bypass-merge-queue force-merge].freeze
  REQUIRED_CHECK = "CI status"

  module_function

  def known_label?(label)
    LABELS.include?(label)
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

  def plan(label:, ci_status_conclusion:)
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
      unless ci_status_conclusion == "success"
        raise PlanError,
              "#{label} requires a successful #{REQUIRED_CHECK.inspect} check " \
              "(got #{ci_status_conclusion.inspect}); use force-merge to override CI too"
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

  class AuthorizationError < StandardError; end
  class PlanError < StandardError; end
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
      ci_status_conclusion: payload.fetch("ci_status_conclusion")
    )
    puts JSON.generate(plan)
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
        ci_status_conclusion: payload.fetch("ci_status_conclusion", "success")
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
