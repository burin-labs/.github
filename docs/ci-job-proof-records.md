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
the bounded live transport. The reader's `inspect_run` returns:

| Field | Meaning |
| --- | --- |
| `producer` | The complete workflow run and attempt that was inspected |
| `registered` | The parsed record and its checked archive identity |
| `census` | The declared job count and all jobs in that attempt |
| `requested` | The job identities being checked |
| `admission` | Jobs that passed and pointers to original runs still to read |

If you omit `wanted`, inspection reads all identities in the record. It uses
the same source, archive, job count, and registrar checks as `read_run`.
The result retains failed jobs; a retained job is not a passing proof.
Reuse and history both call this owner. Empty, partial, mixed, and duplicate
job lists refuse. Archive bytes must match the API digest before parsing.

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
The [CI workflow](../.github/workflows/ci.yml) runs the actual action with a
nonempty identity, uploads its record, then reads back both source fields.
Its smoke identity proves registration transport; it grants no reused CI
verdict.
