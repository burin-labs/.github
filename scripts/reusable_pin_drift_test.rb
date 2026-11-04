# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require_relative "reusable_pin_contract"

script = File.join(__dir__, "reusable-pin-drift.sh")
workflow = File.join(__dir__, "..", ".github", "workflows", "reusable-pin-drift.yml")
source = File.read(script)

# Structural assertions below run against code lines only. The script documents
# its own traps at length - the code-search API it avoids, the pin rule it
# centralises - and matching that prose would assert on the explanation rather
# than the behaviour. It is the same comment-versus-code confusion that makes
# `runs-on` greps unreliable, and that the script itself must defend against
# when deciding whether a matching line is a real `uses:`.
code_only = source.lines.reject { |line| line.strip.start_with?("#") }.join

abort "#{script}: must be executable" unless File.executable?(script)

# ---------------------------------------------------------------------------
# The verdict set is closed
# ---------------------------------------------------------------------------
#
# Every verdict is routed to either the actionable list or the informational
# table by exclusion, so a verdict that exists in the classifier but in neither
# list silently lands in "informational" - it would be reported, look handled,
# and never be acted on. That is the vacuity failure this whole check exists to
# prevent, reproduced one level up. So the two sets must partition exactly.

ACTIONABLE = %w[behind-stale not-on-main broken missing-output target-missing-output].freeze
INFORMATIONAL = %w[current behind-equivalent unpinned-ref].freeze

declared = source[/^ACTIONABLE='(\[.*?\])'/m, 1]
abort "#{script}: ACTIONABLE list not found" unless declared
declared_actionable = declared.scan(/"([a-z-]+)"/).flatten.sort
unless declared_actionable == ACTIONABLE.sort
  abort "#{script}: ACTIONABLE is #{declared_actionable}, expected #{ACTIONABLE.sort}"
end

assigned = source.scan(/^\s*VERDICT="([a-z-]+)"$/).flatten.uniq.sort
expected = (ACTIONABLE + INFORMATIONAL).sort
unless assigned == expected
  abort "#{script}: classifier emits #{assigned}, but the actionable/informational " \
        "partition covers #{expected}. A verdict in neither list is reported as " \
        "informational and never acted on."
end

# `behind-equivalent` and `unpinned-ref` are the majority of rows on this org (26
# of 35 at the time of writing). If either becomes actionable the report turns
# into noise and gets muted, which is strictly worse than not having it.
[["behind-equivalent", "a pin trailing main with byte-identical content"],
 ["unpinned-ref", "a tag/branch ref, which harn's lint-actions-source owns"]].each do |verdict, why|
  next unless ACTIONABLE.include?(verdict)

  abort "#{script}: #{verdict} must not be actionable (#{why})"
end

# ---------------------------------------------------------------------------
# Truth table, exercised offline
# ---------------------------------------------------------------------------
#
# `classify` is answered before any network call precisely so this runs in CI
# without org credentials. `broken` and `unpinned-ref` have no live instance in
# this org, so without these cases they would be asserted only by reading the
# source.

FULL_SHA = ("a" * 40).freeze

CASES = [
  # ref,       relation,    pinned_blob, target_blob, expected verdict
  [FULL_SHA,   "identical", "b1",        "b1",        "current"],
  [FULL_SHA,   "behind",    "b1",        "b1",        "behind-equivalent"],
  [FULL_SHA,   "behind",    "b1",        "b2",        "behind-stale"],
  [FULL_SHA,   "behind",    "",          "b2",        "broken"],
  [FULL_SHA,   "ahead",     "",          "",          "not-on-main"],
  [FULL_SHA,   "diverged",  "",          "",          "not-on-main"],
  [FULL_SHA,   "unknown",   "",          "",          "broken"],
  [FULL_SHA,   "",          "",          "",          "broken"],
  ["v1",       "n/a",       "",          "",          "unpinned-ref"],
  ["main",     "n/a",       "",          "",          "unpinned-ref"],
  ["15a3563fbfb0", "n/a",   "",          "",          "unpinned-ref"],
].freeze

CASES.each do |ref, relation, pinned, target, want|
  out, err, status = Open3.capture3(
    "bash", script, "classify", ref, relation, pinned, target, ".github/workflows/x.yml"
  )
  abort "#{script}: classify #{ref} #{relation} failed: #{err}" unless status.success?

  got = out.split("\t").first.to_s.strip
  next if got == want

  abort "#{script}: classify(ref=#{ref.inspect}, relation=#{relation.inspect}, " \
        "pinned=#{pinned.inspect}, target=#{target.inspect}) = #{got.inspect}, want #{want.inspect}"
end

# ---------------------------------------------------------------------------
# Caller/callee output contracts, exercised offline
# ---------------------------------------------------------------------------

caller = <<~YAML
  on:
    pull_request:
  jobs:
    detector:
      uses: burin-labs/.github/.github/workflows/runner-availability.yml@#{FULL_SHA}
    consumer:
      needs: detector
      if: needs.detector.outputs.capacity != ''
      env:
        LINUX: ${{ needs['detector'].outputs['linux'] }}
        DUPLICATE: ${{ needs.detector.outputs.capacity }}
    local:
      runs-on: ubuntu-latest
      steps:
        # uses: burin-labs/.github/.github/workflows/not-a-call.yml@#{FULL_SHA}
        - run: echo needs.unrelated.outputs.value
YAML

references = ReusablePinContract.references(caller, org: "burin-labs", policy_repo: ".github")
unless references == [{
  job: "detector",
  workflow: ".github/workflows/runner-availability.yml",
  ref: FULL_SHA,
  line: 5,
  required_outputs: %w[capacity linux]
}]
  abort "reusable output reference projection is wrong: #{references.inspect}"
end

# burin-code folds long references onto the next line; the census died on it.
folded = <<~YAML
  jobs:
    runner-availability:
      uses:
        burin-labs/.github/.github/workflows/runner-availability.yml@#{FULL_SHA}
YAML
folded_refs = ReusablePinContract.references(folded, org: "burin-labs", policy_repo: ".github")
abort "a folded uses: reference must resolve to its key line: #{folded_refs.inspect}" unless folded_refs.map { |r| r[:line] } == [3]

callee = <<~YAML
  on:
    workflow_call:
      outputs:
        linux:
          value: ${{ jobs.detect.outputs.linux }}
        capacity:
          value: ${{ jobs.detect.outputs.capacity }}
YAML
unless ReusablePinContract.declared_outputs(callee) == %w[capacity linux]
  abort "reusable output declarations must come from on.workflow_call.outputs"
end

OUTPUT_CASES = [
  # base verdict, required, pinned, target, expected output verdict
  ["current", %w[capacity], [], %w[capacity], "missing-output"],
  ["current", %w[linux], %w[linux], [], "target-missing-output"],
  ["behind-stale", %w[linux], %w[linux], %w[linux], "behind-stale"]
].freeze

OUTPUT_CASES.each do |base, required, pinned, target, want|
  out, err, status = Open3.capture3(
    "bash", script, "classify-outputs", base, "base detail", "detector",
    ".github/workflows/runner-availability.yml", FULL_SHA,
    JSON.generate(required), JSON.generate(pinned), ("b" * 40), JSON.generate(target)
  )
  abort "#{script}: output classification failed: #{err}" unless status.success?

  got = out.split("\t").first.to_s.strip
  next if got == want

  abort "#{script}: output classification #{required}/#{pinned}/#{target} = #{got}, want #{want}"
end

# "Is this a pin" has one owner. The fetching loop needs the same answer as the
# classifier, and two copies could disagree - the loop would compare a ref the
# classifier then reported as unpinned, so the row's relation and its verdict
# would describe different questions.
sha_rule_sites = code_only.scan(/\[0-9a-f\]\{[0-9,]+\}/).length
unless sha_rule_sites == 1
  abort "#{script}: the full-SHA rule appears at #{sha_rule_sites} sites; keep it in is_full_sha only"
end
abort "#{script}: must define is_full_sha" unless code_only.include?("is_full_sha()")

# A 40-hex ref must be treated as a pin and anything shorter must not, because
# `lint-actions-source` draws the same line. Asserted as a property so the regex
# cannot drift to, say, 7-character SHAs.
%w[abcdef1 15a3563fbfb0 15a3563fbfb0da497e1d5e409e64d5fe3b9acc2].each do |short|
  out, = Open3.capture3("bash", script, "classify", short, "n/a", "", "", "x.yml")
  next if out.split("\t").first.to_s.strip == "unpinned-ref"

  abort "#{script}: #{short.length}-character ref #{short} must classify as unpinned-ref"
end

# ---------------------------------------------------------------------------
# Enumeration must not regress to the code-search API
# ---------------------------------------------------------------------------
#
# `search/code` drops results per query: counting burin-code's callers of
# runner-availability.yml returned 7 via search/code and 8 via `git grep`, and
# the file it missed was returned by a different query in the same session. This
# check's only claim is completeness, so that API cannot be the source.
if code_only.match?(%r{search/code})
  abort "#{script}: enumeration must not use the code-search API (drops results per query)"
end

# Every list read must paginate. burin-labs already had a list read return a
# misleading first page (1015 runner registrations, 1002 vendor ephemerals).
code_only.scan(/^.*gh api.*$/).each do |line|
  next unless line.match?(%r{/orgs/|/repos/[^"]*/(issues|contents)\?})
  next if line.include?("--paginate")
  next if line.include?("/compare/") || line.include?("/commits/")
  next if line.match?(%r{contents/\$}) # single-file read, not a list

  abort "#{script}: list read must be paginated: #{line.strip}"
end

# ---------------------------------------------------------------------------
# The issue sync must be idempotent
# ---------------------------------------------------------------------------
#
# Re-running must not file duplicates, and drift clearing must close the report
# rather than leaving a stale open issue asserting drift that no longer exists.
abort "#{script}: must define a stable issue marker" unless source.include?("ISSUE_MARKER=")

sync = source[/# Idempotent issue sync.*\z/m]
abort "#{script}: issue sync section not found" unless sync

unless sync.match?(/gh issue list.*--state open/m) && sync.include?("$ISSUE_MARKER") ||
       sync.include?("${ISSUE_MARKER}")
  abort "#{script}: sync must look for an existing open report by marker before creating one"
end
abort "#{script}: sync must edit an existing report in place" unless sync.include?("gh issue edit")
abort "#{script}: sync must close the report when drift clears" unless sync.include?("gh issue close")

create_index = sync.index("gh issue create")
lookup_index = sync.index("gh issue list")
abort "#{script}: sync must create an issue when none exists" unless create_index
if lookup_index.nil? || lookup_index > create_index
  abort "#{script}: sync must look up the existing report BEFORE creating a new one"
end

# ---------------------------------------------------------------------------
# Workflow wiring
# ---------------------------------------------------------------------------

document = YAML.safe_load(File.read(workflow), aliases: true)
triggers = document["on"] || document[true]
abort "#{workflow}: must be scheduled" unless triggers.is_a?(Hash) && triggers.key?("schedule")

# Without workflow_dispatch the only way to confirm a change to this check is to
# wait for the cron, which is how a broken detector stays broken for a day.
abort "#{workflow}: must be manually dispatchable" unless triggers.key?("workflow_dispatch")

steps = document.fetch("jobs").values.flat_map { |job| job.fetch("steps") }
runs = steps.map { |step| step["run"] }.compact.join("\n")
unless runs.include?("reusable-pin-drift.sh")
  abort "#{workflow}: must invoke scripts/reusable-pin-drift.sh rather than reimplementing it"
end

# The scheduled run must write the report. A workflow that only prints it leaves
# the finding inside a log nobody opens, which is the failure mode that let the
# stale pin survive in the first place.
unless runs.include?("sync-issue")
  abort "#{workflow}: scheduled run must use `sync-issue`, not just `report`"
end

# ---------------------------------------------------------------------------
# Render safety
# ---------------------------------------------------------------------------
#
# The classifier is pure and fully covered above, but the RENDERER produces the
# artifact a human reads, and nothing here executed it before 2026-07-30. A
# printf whose format began with `-` then failed three times, dropping the
# target SHA, the census size and the actionable count from a report that was
# filed and reported as a success. These are structural guards on the two things
# that allowed that.

script_lines = File.readlines(script).each_with_index.map { |line, index| [index + 1, line.rstrip] }
code_lines = script_lines.reject { |_, line| line.strip.start_with?("#") }

# bash's printf builtin parses a leading `-` in the FORMAT as an option and dies
# with `printf: - : invalid option`. Markdown bullet lines hit this constantly.
bad_printf = code_lines.select { |_, line| line.match?(/printf\s+['"]-(?!-)/) }
unless bad_printf.empty?
  detail = bad_printf.map { |number, line| "#{number}: #{line.strip}" }.join("\n  ")
  abort "#{script}: printf format starting with `-` needs the `--` terminator:\n  #{detail}"
end

# Independent of exit codes on purpose: `body="$(render_markdown)"` did NOT
# propagate the failing printf under `set -e`, because errexit is not reliably
# inherited into a command substitution used in an assignment. Only a check on
# the body itself can stop a truncated report from being published.
REQUIRED_REPORT_FIELDS = ["- Target:", "- Workflow files scanned:", "- Actionable:", "- Stale pins:"].freeze

unless code_lines.any? { |_, line| line.include?("require_report_fields") && line.include?("body") }
  abort "#{script}: the rendered body must be checked by require_report_fields before it is published"
end

REQUIRED_REPORT_FIELDS.each do |field|
  next if code_lines.any? { |_, line| line.include?("'#{field}'") }

  abort "#{script}: require_report_fields must assert the `#{field}` field is present"
end

# Each required field must also actually be emitted by the renderer, or the
# check above would fail every run instead of catching a regression.
REQUIRED_REPORT_FIELDS.each do |field|
  next if code_lines.any? { |_, line| line.include?("printf -- '#{field}") }

  abort "#{script}: render_markdown must emit `#{field}` via `printf --`"
end

# ---------------------------------------------------------------------------
# Execution paths: every reusable workflow is derived or listed
# ---------------------------------------------------------------------------
#
# Staleness is only as complete as the path set. A workflow that checks this
# repository out at its own ref, and from which no executed path can be
# derived, must be listed in the explicit table; otherwise its pins would read
# "current" while running stale scripts.

repo_root = File.expand_path("..", __dir__)
head = ReusablePinContract::Tree.new(repo_root, "HEAD")
table = ReusablePinContract.execution_table
reusable = Dir[File.join(repo_root, ".github/workflows/*.y{a,}ml")].sort.filter_map do |file|
  parsed = ReusablePinContract.document(File.read(file))
  triggers = parsed["on"] || parsed[true]
  next unless triggers.is_a?(Hash) && triggers.key?("workflow_call")

  file.delete_prefix("#{repo_root}/")
end
abort "no reusable workflows found; the derivation check would pass vacuously" if reusable.empty?

reusable.each do |path|
  derived = ReusablePinContract.execution_paths(head, path, org: "burin-labs", policy_repo: ".github", table: {})
  next if derived[:unresolved].empty? || table.key?(path)

  abort "#{path}: execution paths are neither derived nor listed in " \
        "scripts/reusable-pin-execution-paths.json: #{derived[:unresolved].join('; ')}"
end

table.each do |path, entry|
  abort "execution-path table lists #{path}, which is not a reusable workflow" unless reusable.include?(path)
  abort "execution-path table entry #{path} must say why" if entry["why"].to_s.strip.empty?

  derived = ReusablePinContract.execution_paths(head, path, org: "burin-labs", policy_repo: ".github", table: {})
  Array(entry["paths"]).each do |listed|
    abort "execution-path table entry #{path} lists missing path #{listed}" unless head.type(listed)
    abort "execution-path table entry #{path} lists derivable path #{listed}; drop it" if derived[:paths].include?(listed)
  end
end

# The real Smart Ship workflow must derive the directory it sparse-checks out.
smart_ship = ReusablePinContract.execution_paths(
  head, ".github/workflows/smart-ship.yml", org: "burin-labs", policy_repo: ".github", table: {}
)
unless smart_ship[:paths].include?("scripts/smart-ship")
  abort "smart-ship.yml must derive scripts/smart-ship, got #{smart_ship[:paths]}"
end

if ReusablePinContract::STALE_GRACE_SECONDS != 2 * 24 * 60 * 60
  abort "STALE_GRACE_SECONDS must be 2 days, is #{ReusablePinContract::STALE_GRACE_SECONDS}"
end

# The census reads pin commits from local history; a shallow checkout makes the
# script refuse to run, so the workflow must fetch full history.
checkout = steps.find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
unless checkout && checkout.dig("with", "fetch-depth").to_s == "0"
  abort "#{workflow}: the census checkout needs fetch-depth: 0 to read pin history"
end

# ---------------------------------------------------------------------------
# Staleness truth table, exercised offline against a fixture repository
# ---------------------------------------------------------------------------
#
# Models the real miss. Consumers pinned smart-ship.yml at
# 80668ab79200fff018943e50079b6fbc6005b196. smart-ship.yml had no newer commits,
# but scripts/smart-ship/ship.harn, which the workflow checks out at its own
# ref, gained the approval-carry fix in a4f6ea4f (#351). A check scoped to the
# workflow file reported 0 newer commits, so the pinned callers never ran it.
# The fixture uses the REAL smart-ship.yml so the derivation under test is the
# one the census applies.

DAY = 24 * 60 * 60
EPOCH = 1_800_000_000
NOW = EPOCH + (10 * DAY)
FIX_SUBJECT = "[CI] Carry an approval across merges of the base branch (#351)"

def fixture_git(dir, *args, time: EPOCH)
  env = {
    "GIT_AUTHOR_DATE" => "@#{time} +0000", "GIT_COMMITTER_DATE" => "@#{time} +0000",
    "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1"
  }
  out, err, status = Open3.capture3(
    env, "git", "-C", dir, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
    "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", *args
  )
  abort "fixture git #{args.join(' ')} failed: #{err}" unless status.success?
  out.strip
end

def fixture_commit(dir, files, subject, time)
  files.each do |path, body|
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end
  fixture_git(dir, "add", "-A", time: time)
  fixture_git(dir, "commit", "-q", "-m", subject, time: time)
  fixture_git(dir, "rev-parse", "HEAD")
end

def measured(dir, pinned, target, workflow: ".github/workflows/smart-ship.yml")
  out, err, status = Open3.capture3(
    "ruby", File.join(__dir__, "reusable_pin_contract.rb"), "staleness",
    dir, "burin-labs", ".github", workflow, pinned, target, NOW.to_s, stdin_data: ""
  )
  abort "staleness #{pinned[0, 8]}..#{target[0, 8]} failed: #{err}" unless status.success?
  JSON.parse(out)
end

smart_ship_source = File.read(File.join(repo_root, ".github/workflows/smart-ship.yml"))
stale_rows = Dir.mktmpdir("pin-staleness-") do |dir|
  fixture_git(dir, "init", "-q")
  pinned = fixture_commit(dir, {
    ".github/workflows/smart-ship.yml" => smart_ship_source,
    "scripts/smart-ship/ship.harn" => "// before the approval-carry fix\n",
    "README.md" => "fixture\n",
    # A self checkout at its own ref with nothing derivable: must be UNKNOWN.
    ".github/workflows/opaque.yml" => <<~YAML
      on:
        workflow_call:
      jobs:
        run:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@#{FULL_SHA}
              with:
                repository: burin-labs/.github
                ref: ${{ fromJSON(toJSON(job)).workflow_sha }}
                path: .impl
            - run: make -C "$IMPL_ROOT" ship
    YAML
  }, "[CI] Pin point", EPOCH)
  unrelated = fixture_commit(dir, { "README.md" => "unrelated\n" }, "[Docs] Unrelated change", EPOCH + DAY)
  fix = fixture_commit(dir, { "scripts/smart-ship/ship.harn" => "// carries the approval\n" }, FIX_SUBJECT, EPOCH + (2 * DAY))
  recent = fixture_commit(dir, { "scripts/smart-ship/ship.harn" => "// recent\n" }, "[CI] Recent Smart Ship change",
                          NOW - DAY)
  target = recent

  # (a) The known stale pin is flagged, with the script commits listed.
  a = measured(dir, pinned, target)
  unless a["state"] == "stale" && a["count"] == 2 && a["paths"].include?("scripts/smart-ship") &&
         a["commits"].map { |c| c["sha"] } == [recent, fix] && a["commits"].last["subject"] == FIX_SUBJECT
    abort "(a) a smart-ship pin with newer scripts/smart-ship commits must be stale and list them: #{a.inspect}"
  end
  abort "(a) an unrelated commit must not be listed" if a["commits"].any? { |c| c["sha"] == unrelated }

  # (b) Negative control: the old logic, scoped to the workflow file, misses it.
  # Both the path-scoped log and the census's existing blob comparison say clean.
  workflow_only = fixture_git(dir, "log", "--format=%H", "#{pinned}..#{target}", "--",
                              ".github/workflows/smart-ship.yml")
  abort "(b) the workflow-file-only log must report 0 newer commits, got #{workflow_only.inspect}" unless workflow_only.empty?
  blob_pinned = fixture_git(dir, "rev-parse", "#{pinned}:.github/workflows/smart-ship.yml")
  blob_target = fixture_git(dir, "rev-parse", "#{target}:.github/workflows/smart-ship.yml")
  old_verdict, = Open3.capture3("bash", script, "classify", pinned, "behind", blob_pinned, blob_target,
                                ".github/workflows/smart-ship.yml")
  unless old_verdict.split("\t").first == "behind-equivalent"
    abort "(b) the file-blob verdict must call this pin behind-equivalent, got #{old_verdict.inspect}"
  end

  # (c) A current pin reports nothing.
  c = measured(dir, target, target)
  abort "(c) a pin at the target must be current with no commits: #{c.inspect}" unless c["state"] == "current" &&
                                                                                       c["count"].zero? && c["commits"].empty?

  # (d) Newer commits inside the grace period are listed but not flagged.
  d = measured(dir, fix, target)
  unless d["state"] == "pending" && d["commits"].map { |commit| commit["sha"] } == [recent]
    abort "(d) a pin trailing only an in-grace commit must be pending and list it: #{d.inspect}"
  end

  # (e) An unreadable pin commit is UNKNOWN, never clean.
  e = measured(dir, "d" * 40, target)
  abort "(e) an unreadable pin must be unknown: #{e.inspect}" unless e["state"] == "unknown" && e["count"].nil?

  # (f) A self checkout with nothing derivable is UNKNOWN unless the table lists it.
  f = measured(dir, pinned, target, workflow: ".github/workflows/opaque.yml")
  abort "(f) an underivable own-ref checkout must be unknown: #{f.inspect}" unless f["state"] == "unknown"

  row = ->(record, ref) { { repo: "burin-code", workflow: record["workflow"], ref: ref, staleness: record } }
  [row.call(a, pinned), row.call(a, pinned), row.call(c, target), row.call(d, fix), row.call(e, "d" * 40)]
end

# The rendered report lists per caller repo, per pin; flags stale and unknown;
# lists pending without flagging it; and omits the current pin entirely.
rendered, err, status = Open3.capture3("bash", script, "render-staleness", "main", stdin_data: JSON.generate(stale_rows))
abort "#{script}: render-staleness failed: #{err}" unless status.success?
lines = rendered.lines.map(&:rstrip)
stale_pinned = stale_rows[0][:ref]
{
  "repo heading" => "### `burin-code`",
  "stale pin" => "- `smart-ship.yml` pinned `#{stale_pinned[0, 8]}` (2 call sites): **stale**, 2 newer commit(s), oldest 8d old",
  "fix commit" => "  - `#{stale_rows[0][:staleness]['commits'].last['sha'][0, 8]}` #{FIX_SUBJECT}",
  "pending pin" => "- `smart-ship.yml` pinned `#{stale_rows[3][:ref][0, 8]}`: pending, 1 newer commit(s), oldest 1d old",
  "unknown pin" => "- `smart-ship.yml` pinned `dddddddd`: **unknown**, pinned commit dddddddd is not readable in burin-labs/.github",
  "count" => "- Stale pins: 2"
}.each do |what, want|
  abort "render-staleness: missing #{what} line #{want.inspect} in:\n#{rendered}" unless lines.include?(want)
end
if rendered.include?("pinned `#{stale_rows[2][:ref][0, 8]}`")
  abort "render-staleness: a current pin must not be reported:\n#{rendered}"
end

puts "reusable-pin-drift policy: ok"
