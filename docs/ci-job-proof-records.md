# CI job proof records

Use these records to inspect where a CI job ran and what source it tested.
The [contract](../scripts/ci-job-proof/contract.harn) owns the types. The
[reader](../scripts/ci-job-proof/reader.harn) owns proof checks and reuse.

## Source fields

The `burin.ci_job_proof_registration.v3` record keeps two source facts:

| Field | Meaning |
| --- | --- |
| `commit` | The head that GitHub reports for the workflow run |
| `tested_source.commit` | The checkout commit when inputs were registered |
| `tested_source.tree` | The tree of that checkout |

For a pull request, GitHub may report the PR head while the job tests a merge
commit. Keep both. The [source reader](../scripts/ci-job-proof/source.harn)
measures Git in the caller's workspace. A dirty or unreadable checkout cannot
publish a record. The checkout must stay the same through proof discovery.
The record does not prove which checkout a later job used if that job changes
source. A consumer must bind its job plan to the registered source.

Version 3 requires the tested source. Version 2 cannot supply that fact and
does not qualify through this reader. Existing callers stay on their pinned
action until they adopt a new pin. A missing proof runs the job.

## Original run inspection

The package's `ci_job_proof` export exposes the reader, its input types, and
the bounded live transport. Use `inspect_original_run(source, policy, producer,
wanted?)` to observe a run from a controller or another workflow. It takes a
trusted `ProducerPolicy`, with no invented consumer run:

| Policy field | Meaning |
| --- | --- |
| `repository` | Exact repository that ran the job, as `owner/name` |
| `workflow` | Exact producer workflow file, such as `ci.yml` |
| `events` | Enrolled producer events, with no empty or duplicate entries |
| `registrarJob` | Exact job name that published the input record |
| `registrarStep` | Exact successful step that published it |

The implemented events are `pull_request`, `merge_group`, `push` and
`workflow_dispatch`. Dispatch observation requires explicit enrollment. The
policy comes from your trusted installation, not from the inspected change.
Supply the producer from an authenticated read of that exact run and attempt.
The bounded `live_source` transport checks the downloaded archive bytes.

The result retains:

| Field | Meaning |
| --- | --- |
| `producer` | The complete workflow run and attempt that was inspected |
| `registered` | The parsed record and its checked archive identity |
| `census` | The declared job count and all jobs in that attempt |
| `requested` | The job identities being checked |
| `admission` | Jobs that passed and pointers to original runs still to read |

If you omit `wanted`, inspection reads all identities in the record. It uses
the same source, archive, job count, and registrar checks as reuse.
The result retains failed jobs; a retained job is not a passing proof.
Empty, partial, mixed, and duplicate job lists refuse. Archive bytes must match
the API digest before parsing. The producer must have finished; its overall
conclusion may be failure when an unrelated job failed.

`inspect_run(source, current, producer, wanted?)` remains the reuse entrypoint.
It projects the existing `RunContext` onto the same verifier. It still requires
a distinct consumer run of the same workflow and accepts only `pull_request`,
`merge_group` and `push` producers. History keeps that policy too. Enrolling a
dispatch observer grants no new reuse authority to existing callers.

Inspection returns facts and logical job proofs. It does not sign a Smart Ship
receipt, admit a change, merge work or qualify a release. A consumer still has
to bind those facts to its trusted job plan and release policy.

## Action output

The action's `registration` output is the local path to the JSON record it
uploads for this attempt. An empty output means no record was published.
The `receipt` output still names only jobs whose original passing proof was
found. Neither output lets a consumer skip the reader's checks.

## Verification

The [source test](../scripts/ci-job-proof/source_test.harn) measures a real
Git checkout and rejects tracked edits, untracked input, and a missing path.
The [archive test](../scripts/ci-job-proof/product_test.harn) retains a tested
merge distinct from the run head, the archive digest, and the full job list.
It observes an explicitly enrolled dispatch and refuses a different workflow,
attempt, active run, empty policy and missing event enrollment. The same test
confirms that the existing path still refuses self-reuse and dispatch reuse.
The [CI workflow](../.github/workflows/ci.yml) runs the actual action with a
nonempty identity, uploads its record, then reads back both source fields.
Its smoke identity proves registration transport; it grants no reused CI
verdict.
