# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "time"
require_relative "check-release-integrity"

class CheckReleaseIntegrityTest < Minitest::Test
  CHECKER = File.expand_path("check-release-integrity.rb", __dir__)
  NOW = Time.parse("2026-08-02T12:00:00Z")

  def tag(name, age_seconds: 86_400)
    {"name" => name, "date" => (NOW - age_seconds).utc.iso8601}
  end

  def release(name, draft: false)
    {"tag_name" => name, "draft" => draft}
  end

  def codes(tags:, releases:, grace_seconds: HarnReleaseIntegrity::DEFAULT_GRACE_SECONDS)
    HarnReleaseIntegrity
      .violations(tags: tags, releases: releases, now: NOW, grace_seconds: grace_seconds)
      .map(&:code)
  end

  def test_a_repository_whose_tags_all_have_releases_is_clean
    tags = [tag("v0.1.0"), tag("v0.2.0")]
    releases = [release("v0.1.0"), release("v0.2.0")]

    assert_empty codes(tags: tags, releases: releases)
    assert HarnReleaseIntegrity.check!(tags: tags, releases: releases, now: NOW)
  end

  # harn-github-connector v0.6.7: the tag was signed and pushed, then the release
  # job's package verification failed, so no release was ever published.
  def test_a_tag_whose_release_job_failed_is_a_violation
    codes = codes(tags: [tag("v0.6.7")], releases: [])

    assert_equal ["tag_without_release"], codes
  end

  def test_the_violation_names_the_offending_tag
    error = assert_raises(HarnReleaseIntegrity::Violation) do
      HarnReleaseIntegrity.check!(tags: [tag("v0.6.7")], releases: [], now: NOW)
    end

    assert_equal "v0.6.7", error.tag
    assert_includes error.report, "v0.6.7"
    assert_includes error.report, "tag_without_release"
  end

  # The publishing job needs a few minutes between the tag push and the releases
  # API call. CI for the release commit overlaps that window, so a fresh tag
  # must not turn the release commit red.
  def test_a_tag_pushed_moments_ago_is_still_in_flight
    assert_empty codes(tags: [tag("v0.6.8", age_seconds: 120)], releases: [])
  end

  def test_a_tag_left_unpublished_past_the_grace_window_is_a_violation
    codes = codes(tags: [tag("v0.6.8", age_seconds: 5_400)], releases: [])

    assert_equal ["tag_without_release"], codes
  end

  def test_the_grace_window_is_configurable
    fresh = [tag("v0.6.8", age_seconds: 120)]

    assert_empty codes(tags: fresh, releases: [], grace_seconds: 3_600)
    assert_equal ["tag_without_release"], codes(tags: fresh, releases: [], grace_seconds: 60)
  end

  # A draft release is invisible to consumers, so it is not a published release.
  def test_a_draft_release_does_not_satisfy_the_invariant
    codes = codes(tags: [tag("v0.1.0")], releases: [release("v0.1.0", draft: true)])

    assert_equal ["release_still_draft"], codes
  end

  def test_a_release_whose_tag_was_deleted_is_a_violation
    codes = codes(tags: [], releases: [release("v0.1.0")])

    assert_equal ["release_without_tag"], codes
  end

  # Deployment markers and upstream naming schemes are not release tags and must
  # not be dragged into this invariant.
  def test_non_release_tags_are_ignored
    tags = [
      tag("render-api-deployed"),
      tag("release-2026-03-30"),
      tag("wayland-backend-v0.3.3"),
      tag("v0.30.0-beta.1"),
      tag("0.2.0"),
    ]

    assert_empty codes(tags: tags, releases: [])
  end

  def test_every_offending_tag_is_reported_not_just_the_first
    tags = [tag("v0.6.1"), tag("v0.6.7"), tag("v0.6.8")]
    releases = [release("v0.6.8")]

    found = HarnReleaseIntegrity.violations(tags: tags, releases: releases, now: NOW)

    assert_equal %w[v0.6.1 v0.6.7], found.map(&:tag)
  end

  def test_an_undatable_tag_is_treated_as_old_rather_than_forgiven
    tags = [{"name" => "v0.1.0", "date" => nil}]

    assert_equal ["tag_without_release"], codes(tags: tags, releases: [])
  end

  def test_the_command_line_entry_point_reports_and_fails
    payload = JSON.dump("tags" => [tag("v0.6.7")], "releases" => [])
    stdout, stderr, status = Open3.capture3("ruby", CHECKER, stdin_data: payload)

    refute_predicate status, :success?
    assert_empty stdout
    assert_includes stderr, "v0.6.7"
    assert_includes stderr, "tag_without_release"
  end

  def test_the_command_line_entry_point_succeeds_on_a_clean_repository
    payload = JSON.dump("tags" => [tag("v0.1.0")], "releases" => [release("v0.1.0")])
    _stdout, stderr, status = Open3.capture3("ruby", CHECKER, stdin_data: payload)

    assert_predicate status, :success?
    assert_empty stderr
  end

  def test_the_command_line_entry_point_honours_the_grace_override
    # The entry point dates tags against the real clock, so this fixture must be
    # anchored there rather than to the frozen NOW the pure checks use.
    just_pushed = {"name" => "v0.6.8", "date" => (Time.now - 120).utc.iso8601}
    payload = JSON.dump("tags" => [just_pushed], "releases" => [])

    _out, _err, relaxed = Open3.capture3("ruby", CHECKER, stdin_data: payload)
    assert_predicate relaxed, :success?

    _out, _err, strict = Open3.capture3(
      {"RELEASE_INTEGRITY_GRACE_SECONDS" => "60"}, "ruby", CHECKER, stdin_data: payload
    )
    refute_predicate strict, :success?
  end
end
