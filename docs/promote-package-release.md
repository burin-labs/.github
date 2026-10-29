# Promote a package release from a shared repository

Use the shared release promoter when one repository holds both an application
and a separately versioned package. Give the package its own tag, such as
`harn-smart-ship/v0.1.0`. The promoter publishes the tested files without changing
the repository's latest release.

## Prepare the candidate

Build and test the package in your existing CI workflow. Upload the exact files,
their build attestations, and a
[candidate manifest](../schemas/candidate-manifest.v1.json) from that run.
Use `kind: archive` and `target: portable` for a platform-independent package
archive. Include its checksum file and one release-notes file. Mark native
signing and notarization as `not_applicable` when the archive contains source.

The source commit must be on the default branch. The run must finish
successfully before promotion starts. Retain its exact source SHA and run ID;
an empty or incomplete candidate cannot be promoted.

## Call the promoter

Pin the shared workflow to a verified commit and pass the package tag:

```yaml
jobs:
  promote:
    uses: burin-labs/.github/.github/workflows/promote-release.yml@<verified-commit>
    permissions:
      contents: read
      actions: read
      attestations: read
    with:
      sha: ${{ inputs.candidate_sha }}
      run-id: ${{ inputs.candidate_run_id }}
      tag: harn-smart-ship/v0.1.0
    secrets:
      RELEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_APP_CLIENT_ID }}
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

The namespace is one component with letters or digits joined by a dot,
underscore, or hyphen. It cannot end in `.lock`. The version follows the same
`vX.Y.Z` or `vX.Y.Z-suffix` form as a root release tag. Extra path components are
refused. A suffix marks a prerelease; hyphens in the package name do not.

Scope application tag triggers to root tags so a package tag cannot start the
application's release workflow. Promotion creates an annotated tag at the
tested source, checks the uploaded assets and release body, and publishes those
same files. A stable package release is a normal release with `latest: false`.
A package prerelease also remains outside latest. Root stable releases still
update latest; root prereleases do not.

## Resume an interrupted promotion

Rerun promotion with the same source SHA, producer run ID and tag. Keep the
original candidate artifacts; do not rebuild them to repair an upload failure.
The workflow re-verifies the candidate and retains its publication intent for
30 days before obtaining write authority.

The promoter adopts a matching draft, checks every stored asset digest, and
uploads only missing files. If publication already succeeded, it checks the
published release and exact tag target and returns that release. It refuses a
different source, body, prerelease setting, unexpected asset, duplicate asset,
incomplete upload or changed digest. Preserve the draft and retained proof when
it refuses; diagnose the named conflict before another attempt. Same-tag
promotions serialize without cancelling the active publisher.

After creating a draft, the promoter reads its returned ID, tag and release
listing up to six times. Missing results back off for 1, 2, 4, 8 and 16 seconds.
A conflicting identity or body fails immediately. If the draft remains missing,
promotion stops before uploading assets or creating a tag; recover through the
same workflow after diagnosing visibility.

## Register the package

After publication, register the immutable archive URL and checksum with the
package index. Use the package tag's release page as provenance. Confirm that
a fresh consumer installs and imports that exact artifact before changing
downstream pins. Publishing a release and registering its package are separate
results.
