# frozen_string_literal: true

require "json"
require "set"
require "time"

# A release tag is the only thing consumers can pin, so a tag that no release
# stands behind is a promise the repository never kept. These repositories
# publish by pushing a tag, which means every gate -- manifest version, changelog
# notes, package verification -- runs against an object that is already immutable
# and signed. A gate that fails there cannot be repaired in place: the version is
# burned and the tag is stranded. This check refuses to let that state survive
# past the release window it takes to publish.
module HarnReleaseIntegrity
  # A tag pushed seconds ago is not yet a defect. The publishing job still has to
  # install Harn, verify the package, and call the releases API, and CI for the
  # release commit routinely overlaps that window. Anything still unpublished an
  # hour later is a failure, not a race.
  DEFAULT_GRACE_SECONDS = 3600

  RELEASE_TAG = /\Av\d+\.\d+\.\d+\z/

  class Violation < StandardError
    attr_reader :code, :tag

    def initialize(tag:, code:, message:)
      @tag = tag
      @code = code
      super(message)
    end

    def report
      "#{tag}: [#{code}] #{message}"
    end
  end

  module_function

  def release_tag?(name)
    RELEASE_TAG.match?(name.to_s)
  end

  # tags:     [{"name" => "v0.1.0", "date" => "2026-01-01T00:00:00Z"}, ...]
  #           "date" may be nil for tags the caller did not need to date.
  # releases: [{"tag_name" => "v0.1.0", "draft" => false}, ...]
  def violations(tags:, releases:, now: Time.now, grace_seconds: DEFAULT_GRACE_SECONDS)
    published = releases.each_with_object({}) do |release, index|
      index[release["tag_name"].to_s] = release
    end
    tag_names = tags.map { |tag| tag["name"].to_s }.to_set

    found = []

    tags.each do |tag|
      name = tag["name"].to_s
      next unless release_tag?(name)

      release = published[name]

      if release.nil?
        next if within_grace?(tag["date"], now, grace_seconds)

        found << Violation.new(
          tag: name,
          code: "tag_without_release",
          message: "release tag has no published GitHub release; " \
                   "the tag push either never triggered the release workflow or that run failed",
        )
        next
      end

      next unless release["draft"]

      found << Violation.new(
        tag: name,
        code: "release_still_draft",
        message: "release exists but is still a draft, so consumers cannot see it",
      )
    end

    releases.each do |release|
      name = release["tag_name"].to_s
      next unless release_tag?(name)
      next if tag_names.include?(name)

      found << Violation.new(
        tag: name,
        code: "release_without_tag",
        message: "release refers to a tag that no longer exists in the repository",
      )
    end

    found.sort_by(&:tag)
  end

  def within_grace?(date, now, grace_seconds)
    return false if date.nil? || date.to_s.empty?

    now - Time.parse(date.to_s) < grace_seconds
  rescue ArgumentError
    # An undatable tag is treated as old rather than silently forgiven.
    false
  end

  def check!(tags:, releases:, now: Time.now, grace_seconds: DEFAULT_GRACE_SECONDS)
    found = violations(tags: tags, releases: releases, now: now, grace_seconds: grace_seconds)
    raise found.first unless found.empty?

    true
  end
end

if $PROGRAM_NAME == __FILE__
  payload = JSON.parse(ARGF.read)
  grace = Integer(ENV.fetch("RELEASE_INTEGRITY_GRACE_SECONDS", HarnReleaseIntegrity::DEFAULT_GRACE_SECONDS))
  found = HarnReleaseIntegrity.violations(
    tags: payload.fetch("tags", []),
    releases: payload.fetch("releases", []),
    grace_seconds: grace,
  )

  found.each { |violation| warn violation.report }
  exit(found.empty? ? 0 : 1)
end
