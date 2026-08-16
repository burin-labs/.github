# Security policy

This is the Burin Labs organization default. It applies to every repository in
the organization that does not ship its own `SECURITY.md`; a repository-local
policy always wins over this one.

## Reporting a vulnerability

Email **[security@harn.cloud](mailto:security@harn.cloud)** with the
details. Encrypt with our public key if the report contains exploit material
(key available on request).

Please include:

- a clear description of the issue and the impact (e.g. arbitrary code
  execution, sandbox escape, credential or secret exposure, supply-chain
  tampering with a published artifact)
- a minimal reproduction
- the affected repository, version, and platform
- whether the issue has been disclosed publicly or to other parties

Do not open a public issue or pull request for a suspected vulnerability, and
do not include live credentials in the report — describe the exposure and its
location instead.

## Response window

We aim to:

- acknowledge new reports within **2 business days**
- triage and confirm (or dispute) within **5 business days**
- ship a fix or mitigation within **30 days** for confirmed issues, faster for
  actively-exploited or supply-chain bugs

## Scope

In scope: source, build, release, and CI surfaces of Burin Labs repositories,
including anything that lets an attacker ship unintended code to a user,
extract credentials, or escape the boundary a component says it enforces.

Out of scope: vulnerabilities in third-party dependencies (report those to the
appropriate upstream, then tell us so we can pin or patch), and findings that
require an attacker to already hold the credentials or access the component is
protecting.

Several repositories publish a narrower policy of their own, naming the
components an attacker would actually reach. Check the repository's own
Security tab first; what you find there supersedes this section.

## Coordinated disclosure

We support coordinated disclosure. Please give us the response window above
before publishing details. We will credit reporters in the release notes for
the fix unless asked otherwise.
