# bitbison-labs/github

Capture build provenance in GitHub Actions with [Bitbison](https://bitbison.io/).

For installation, open your Bitbison user portal. Navigate to the Builds page
on the left pane and follow the installation guide.

Provide `channel`, `token`, and `instance` from the installation guide using
GitHub Actions secrets.

`github-token` defaults to the job token and needs `actions: read`.

## Review pull requests with Claude

Claude reviews your pull requests with [Bitbison](https://bitbison.io/), in
two reviews:

- **Dependencies**, as soon as a pull request changes. Bitbison works out the
  direct dependencies it adds or upgrades, and every submodule it adds,
  moves or points elsewhere, against the base branch. Each dependency is
  taken through your organization's Bitbison grant workflow: what your rules
  grant is granted, a request is made for the rest, and Claude reviews only
  what is still uncovered, deeper (the registry's analysis and capture of the
  release, alternatives your organization already uses) and comments on it.
  One summary comment, kept up to date, says where every change stands and
  what a person must still decide.
- **Build**, once a build has run under the build integration above and
  been analyzed: a report of what the build itself did (its verdict
  against the default branch's, its findings, the hosts it connected to,
  the packages an advisory names, what it produced), published on the
  job's summary, and Claude's analysis when the build is not clean. As a
  gate between a build and what depends on it, it can also stop a publish
  (below).

Neither review holds up a pull request or fails it unless you ask. Both run
in jobs of their own, never on your build's runner, and only they hold the
Claude credential and the Bitbison CI token. The review's instructions come
from your Bitbison instance, which keeps them current; Claude and the
Bitbison client run on your runner, with your Claude credential. Pull
requests from forks are not reviewed.

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

The build review follows every workflow and says within a minute when a run
had no Bitbison build; name the workflows that build under Bitbison in place
of `"**"` to follow those alone. GitHub runs a `workflow_run` workflow from
the default branch, so the build review starts once this file is merged.

### Options

Under `with:`:

- `dependency-grants: false`: the dependency review only reads and requests
  nothing.
- `fail-on-uncovered: true`: the dependency review fails the job when a
  change is left uncovered.
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
analysis of the run's build, publishes the report on its job's summary,
and fails when the gate does, so a job that `needs` it does not run:

```yaml
jobs:
  build:
    # ... the build, under the build integration
  bitbison:
    needs: build
    permissions:
      contents: read
      pull-requests: read
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
