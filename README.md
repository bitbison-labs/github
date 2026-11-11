# bitbison-labs/github

Capture build provenance in GitHub Actions with [Bitbison](https://bitbison.io/).

For installation, open your Bitbison user portal. Navigate to the Builds page
on the left pane and follow the installation guide.

Provide `channel`, `token`, and `instance` from the installation guide using
GitHub Actions secrets.

`github-token` defaults to the job token and needs `actions: read`.

## Review pull requests and pushes with Claude

Claude reviews your pull requests and pushes with
[Bitbison](https://bitbison.io/), in two reviews:

- **Dependencies**, as soon as a pull request changes, or on a push.
  Bitbison works out the direct dependencies it adds or upgrades, and every
  submodule it adds, moves or points elsewhere, against the base branch. A
  push to the default branch is reviewed by coverage instead: every direct
  dependency the branch pins that no grant covers and no one has asked for
  yet, whatever commits came before, and what the push brought since the
  state Bitbison last recorded; nothing is fetched, and a failed or missed
  run is made good by the next. What the branch already pinned when
  Bitbison first recorded it is left to a person's `bitbison grant
  baseline`, and the summary says how many. Each dependency is
  taken through your organization's Bitbison grant workflow: what your rules
  grant is granted, a request is made for the rest, and Claude reviews only
  what is still uncovered, deeper (the registry's analysis and capture of the
  release, alternatives your organization already uses) and comments on it.
  One summary comment, kept up to date, says where every change stands and
  what a person must still decide. For a push, the summary and Claude's
  notes appear in the job summary. For both pull requests and pushes, the
  job annotation reports whether changes are denied, waiting on a person,
  or covered.
- **Build**, once a build has run under the build integration above and
  been analyzed: a report of what the build itself did (its verdict
  against the default branch's, its findings, the hosts it connected to,
  the packages an advisory names, what it produced), published on the
  job's summary, and Claude's analysis when the build is not clean. As a
  gate between a build and what depends on it, it can also stop a publish
  (below).

Both reviews only report by default. For the dependency review, this is
`fail-on: never`; the `fail-on` option below controls when its job fails. A
failed job blocks a merge only when it is a required check.

Both run in jobs of their own, never on your build's runner, and only they
hold the Claude credential and the Bitbison CI token. The review's
instructions come from your Bitbison instance, which keeps them current;
Claude and the Bitbison client run on your runner, with your Claude
credential. Pull requests from forks are not reviewed.

### Setup

1. In your Bitbison user portal, have an administrator create a CI token for
   the reviewer, with the `mcp/ci/runtime` capability. It reads the registry
   and each run's analysis report, requests grants and submits audits as an
   agent, and lets the build review follow a finding into the build's capture,
   through views that mask command lines, paths and other free text; it reads
   nothing of your hosts. A token with `mcp/ci` alone does both reviews from
   the analysis report, without the capture.
2. Add secrets to the repository or its organization:
   - `BITBISON_CI_TOKEN`: the CI token.
   - `ANTHROPIC_API_KEY`: a Claude API key, or `CLAUDE_CODE_OAUTH_TOKEN`, or
     neither with workload identity federation (below).
   - With the build integration, `BITBISON_INSTANCE` and `BITBISON_CHANNEL`
     are already there. Without it, add `BITBISON_INSTANCE` (your instance
     URL) and `BITBISON_ORGANIZATION` (your organization id).
3. Add this workflow and merge it:

```yaml
name: Bitbison review

on:
  pull_request:
  workflow_run:
    workflows: ["**"]
    types: [completed]

jobs:
  review:
    permissions:
      contents: read
      pull-requests: write
      id-token: write
    uses: bitbison-labs/github/.github/workflows/review.yml@<commit>
    secrets: inherit
```

To review each push to the default branch as well, add `push`. Another
branch's changes are reviewed on its pull request, and a push that changes
no dependency asks Claude nothing.

Each push, tag, deletion and run asked for by hand also records the state
of the ref checked out: everything its tree pins, and every branch and tag
the repository has. Each grant then shows where its release is in use,
since when, and when it stopped being used. Every snapshot stands alone: a
set already recorded only marks the ref as seen, and a branch or tag no
longer in the repository ends, even if its `delete` was missed. Leave
`push` unfiltered so each push marks its branch as seen; a paths filter
makes a branch look last seen when its lockfiles last changed. A push to
another branch, a branch's first push, a tag, a deletion and
`workflow_dispatch` are recorded with no review. `track` narrows what is
recorded besides the default branch, which is always recorded: `all` (the
default), or a comma list of `branches` and `tags`; `default-branch`
records it alone.

```yaml
on:
  pull_request:
  push:
    branches: ['**']
    tags: ['**']
  delete:
  workflow_dispatch:
```

The build review follows every workflow and says within a minute when a run
had no Bitbison build; name the workflows that build under Bitbison in place
of `"**"` to follow those alone. GitHub runs a `workflow_run` workflow from
the default branch, so the build review starts once this file is merged.

### Options

Under `with:`:

- `dependency-grants: false`: the dependency review only reads and requests
  nothing.
- `fail-on`: when the dependency review job fails. A failed job blocks a
  merge only when it is a required check.
  - `never` (default): only report.
  - `denied`: fail only on a denied change.
  - `uncovered`: fail on any change without a grant, including denied
    changes and changes waiting on a person.

  Regardless of `fail-on`, the review reports one of three states in the
  summary comment (the job summary for a push) and the job annotation:
  - **Denied** (error annotation): your organization has said no to at
    least one change, through a `deny` rule, the built-in rule for a
    release reviewed or reported as malicious, an approved deny audit, or a
    revoked grant.
  - **Waiting on a person** (warning annotation): no change is denied, but
    at least one has no grant yet.
  - **Covered** (notice annotation): every change has a grant.

  An agent cannot lift a denial. To deny changes based on a review's
  conclusion or an advisory, add a `deny` rule in Bitbison.

  `fail-on-uncovered: true` is the old spelling of `fail-on: uncovered`.
- `vulnerabilities: high` (or `critical`, `medium`, `low`): Claude also
  judges whether the advisories of the direct dependencies a pull request
  or a push adds or upgrades, at that severity or above, are relevant to your code
  (it searches before it reads), and names the way out: a fixed version,
  an alternative your organization uses, or a mitigation. An unrated
  advisory counts as `low`. `off` by default. The summary lists every
  advisory, linked, either way, and Claude never starts when none reaches
  the threshold.
- `runs-on`: the reviews' runner, as JSON: `'["self-hosted", "linux"]'` or
  `'{"group": "reviewers"}'`. A self-hosted runner needs `curl`, `jq`, `gh`
  and `git`.
- `model`: the Claude model to review with.
- `anthropic-federation-rule-id` and `anthropic-organization-id` (optionally
  `anthropic-service-account-id`, `anthropic-workspace-id`): Claude is
  reached through workload identity federation with the job's OIDC token, in
  place of a stored key.
- `wait-minutes`: how long the build review waits for the analysis (15).

### Gate a publish on the build

Put the gate between the build and what depends on it. It waits for the
analysis of the run's build, publishes the report as a check on the
commit (the pull request's Checks tab shows it, "Bitbison build report")
and on its job's summary, and fails when the gate does, so a job that
`needs` it does not run:

```yaml
jobs:
  build:
    # ... the build, under the build integration
  bitbison:
    needs: build
    permissions:
      contents: read
      pull-requests: read
      checks: write
      id-token: write
    uses: bitbison-labs/github/.github/workflows/gate.yml@<commit>
    with:
      gate: agent
    secrets: inherit
  publish:
    needs: [build, bitbison]
    # ...
```

| `gate` | A clean build | A build that is not clean |
|---|---|---|
| `report` (default) | passes | passes, with the report |
| `block` | passes | fails until a person accepts its findings with a policy, or the change removes them |
| `agent` | passes | Claude decides whether what was flagged is a real risk: one fails, none passes, its reason for each finding on the summary |
| `off` | does nothing | does nothing |

Claude never runs on a clean build. On one that is not, `analysis: true`
(the default) has Claude say what the build did, whether it is a real risk
and what to do; `analysis: false` publishes the report alone (`gate:
agent` needs the analysis). `on-timeout` is `pass` or `fail` when the
analysis has not landed in `wait-minutes`.

The reviews comment as `github-actions[bot]`, with the job token. To run a
review in a job of your own, use `bitbison-labs/github/review` as a step; its
inputs are in [`review/action.yml`](review/action.yml), among them
`github-token`: a GitHub App's token there makes the comments that app's.

Repository code is licensed under [Apache-2.0](LICENSE). Downloaded Bitbison
components are covered by their own terms.

[Contributing](CONTRIBUTING.md) · [Security reporting](SECURITY.md)
