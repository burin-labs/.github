# Released Harn pins on Burin main

You must pin a published Harn release in `.harn-version` and remove
`.harn-revision` before shipping to Burin main. Smart Ship, the merge controller,
reads both files at the candidate head before it can merge or enqueue your
approved pull request.

The [pin policy](../scripts/smart-ship/runtime-pin.harn) checks the published
release, resolves its tag to a source commit, and reads the runtime version at
that commit. Your pin, the tag, and the runtime version must agree. Missing
files, failed reads, unpublished releases, and mismatched identities block the
merge. The [merge-path tests](../scripts/smart-ship/runtime-pin-integration_test.harn)
prove both the refusal and a matched release. They also prove that the blocked
comment and `ship-needs-you` label stay when the policy refuses a merge.

You can still use a source pin to test a pull request. Replace it with the
released tag before shipping to main. Burin's strict main and merge-group check
imports the same pin policy as a backstop.

The implementation and typed package export are
[`runtime-pin.harn`](../scripts/smart-ship/runtime-pin.harn). Other repositories
retain their existing runtime-pin policies.
