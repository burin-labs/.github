#!/usr/bin/env ruby
# frozen_string_literal: true

# Fail a pull request whose commits GitHub cannot verify.
#
# WHY THIS EXISTS. `required_signatures` in the org ruleset blocks a merge on an
# unverified commit, and it does so WITHOUT producing a failing check. The PR
# sits at mergeStateStatus=BLOCKED with a fully green board, zero failures, and
# nothing in the rollup to point at. Two instances so far (burin-code
# `backup/5559-before-identity-rewrite` on 2026-07-29, and burin-code#6442 on
# 2026-08-17) each cost hours of stall plus a manual diagnosis, because no signal
# lies: every check really did pass.
#
# The commonest cause is not a missing signature at all. It is a GOOD signature
# under an email GitHub cannot map to a user, which reports as reason `no_user`.
# `git log --show-signature` says `G` locally, so the branch looks clean from the
# machine that produced it. Only GitHub's view disagrees, and only at merge time.
#
# This turns that silence into a named red check that names the offending commit,
# the identity it used, and the reason GitHub gave.
#
# Pure parse-and-decide over a commits payload fetched by the caller, so the
# whole policy is testable without a network or a token.

require "json"

# GitHub reports exactly one verified state. Every other reason is a failure, but
# they need different repair advice, so the ones we have actually seen in this
# org carry a hint.
REASON_HINTS = {
  "no_user" => "signing identity's email is not a verified email on any GitHub account",
  "unverified_email" => "committer email is registered but not verified on the account",
  "bad_email" => "committer email does not match the signature's identity",
  "unknown_key" => "signing key is not registered on the GitHub account",
  "unsigned" => "commit carries no signature at all",
  "unknown_signature_type" => "signature type is one GitHub does not verify",
  "malformed_signature" => "signature is present but unparseable",
  "invalid" => "signature does not match the commit contents",
  "not_signing_key" => "key is registered for authentication, not for signing",
  "expired_key" => "signing key has expired",
  "ocsp_revoked" => "signing certificate was revoked",
}.freeze

# GitHub's pulls/{n}/commits endpoint returns at most this many commits.
API_COMMIT_CAP = 250

Offender = Struct.new(:sha, :reason, :identity, :summary, keyword_init: true)

# The identity that actually decides verification is the committer's, not the
# author's. Report both when they differ so a rebased or merged commit does not
# send someone to fix the wrong one.
def identity_for(commit)
  author = commit.dig("author", "email")
  committer = commit.dig("committer", "email")
  return "committer #{committer}" if author.nil? || author == committer
  return "author #{author}" if committer.nil?

  "committer #{committer}, author #{author}"
end

def offenders_in(commits)
  commits.filter_map do |entry|
    commit = entry["commit"] || {}
    verification = commit["verification"] || {}
    next if verification["verified"] == true

    reason = verification["reason"].to_s
    reason = "missing verification payload" if reason.empty?
    Offender.new(
      sha: entry["sha"].to_s,
      reason: reason,
      identity: identity_for(commit),
      summary: commit["message"].to_s.lines.first.to_s.strip,
    )
  end
end

def render_failure(offenders, total)
  lines = []
  lines << "#{offenders.length} of #{total} commit(s) are not signature-verified by GitHub."
  lines << ""
  offenders.each do |offender|
    hint = REASON_HINTS[offender.reason]
    detail = hint ? "#{offender.reason} (#{hint})" : offender.reason
    lines << "  #{offender.sha[0, 9]}  #{detail}"
    lines << "    identity: #{offender.identity}"
    lines << "    subject:  #{offender.summary}" unless offender.summary.empty?
  end
  lines << ""
  lines << "The org ruleset requires verified signatures, so this PR cannot merge"
  lines << "until every commit above is replaced. Note that a locally-good signature"
  lines << "(`git log --show-signature` printing `G`) is NOT sufficient: GitHub also"
  lines << "has to be able to attribute the signing identity to an account."
  lines << ""
  lines << "Repair means rewriting those commits, which means a force-push. Disarm"
  lines << "auto-merge first if it is armed."
  lines.join("\n")
end

def run(payload_path:, pull_request:)
  # Anti-vacuity. A gate that examines nothing must never report green: that is
  # the failure mode this check was built to remove, so it must not reproduce it.
  unless File.exist?(payload_path)
    warn "::error::commits payload #{payload_path} was never written; refusing to certify"
    return 2
  end

  raw = File.read(payload_path)
  begin
    commits = JSON.parse(raw)
  rescue JSON::ParserError => e
    warn "::error::commits payload is not valid JSON: #{e.message}"
    return 2
  end

  unless commits.is_a?(Array)
    warn "::error::commits payload is #{commits.class}, expected an array"
    return 2
  end

  if commits.empty?
    warn "::error::PR ##{pull_request} reported zero commits; refusing to certify an empty read"
    return 2
  end

  # The pulls/{n}/commits endpoint returns at most 250 commits. Landing exactly
  # on the cap means the read may be partial, and certifying a partial read is
  # the same vacuity this check exists to remove.
  if commits.length >= API_COMMIT_CAP
    warn "::error::PR ##{pull_request} hit the #{API_COMMIT_CAP}-commit API cap; " \
         "the commit list may be truncated and cannot be certified. Split the PR."
    return 2
  end

  offenders = offenders_in(commits)
  if offenders.empty?
    puts "All #{commits.length} commit(s) on PR ##{pull_request} are signature-verified."
    return 0
  end

  message = render_failure(offenders, commits.length)
  warn "::error::#{message.lines.first.strip}"
  warn message
  1
end

if $PROGRAM_NAME == __FILE__
  exit run(
    payload_path: ENV.fetch("COMMITS_PAYLOAD"),
    pull_request: ENV.fetch("PULL_REQUEST_NUMBER", "?"),
  )
end
