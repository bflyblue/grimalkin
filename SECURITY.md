# Security policy

## Supported versions

Grimalkin is experimental 0.x software. Security fixes are made on the latest
release and the `main` branch; older releases are not maintained separately.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature from the
repository's **Security** tab. Do not open a public issue for a vulnerability
that has not been coordinated and fixed.

Include the affected version and platform, reproduction steps, expected impact,
and any suggested mitigation. Please avoid including secrets, personal data, or
terminal output unrelated to the report. You should receive an acknowledgement
within seven days, followed by updates as the report is investigated.

If private vulnerability reporting is not available, email
[Shaun Sharples](mailto:shaun.sharples@gmail.com). Do not disclose the report
in Issues.

## CI and self-hosted runner trust

Grimalkin's persistent self-hosted runners have access to maintainer machines
and the local network. Workflow definitions from `main` therefore classify an
event before any checked-out change can select a runner. Trusted execution is:

- a push to the blessed `main` branch;
- a manual dispatch using `main`; or
- a pull request authored and updated by the repository owner whose head branch
  belongs directly to this repository, not a fork.

Trusted CI runs the complete Linux, Apple Silicon macOS, and Windows matrix on
maintainer-controlled runners. All other pull requests are untrusted regardless
of approval state or collaborator association and run the same platform matrix
on ephemeral GitHub-hosted Ubuntu, macOS, and Windows runners. Trusted and
untrusted dependency caches have separate key namespaces. Trusted macOS and
Windows jobs populate caches that are reused by releases; trusted `main` also
prebuilds read-only seed namespaces for GitHub-hosted jobs. Each untrusted pull
request writes to its own numbered namespace and may restore only its own prior
artifacts or those trusted seeds, so one contributor cannot supply another
contributor's required-check cache. Cache keys include the pinned toolchain,
dependency manifest, and Ghostty revision, so changing any of those inputs
creates a new immutable cache.

`.github/workflows/pr-ci.yml` uses `pull_request_target` solely as a dispatcher
whose definition comes from `main`. It evaluates GitHub-generated actor, author,
and head-repository metadata, then passes the exact head SHA to the reusable
platform workflow. The dispatcher does not itself check out or execute pull
request code. Do not broaden its trusted checks, pass secrets to PR CI, or add a
direct `pull_request` path that PR-edited YAML could route to `self-hosted`.

Container environments used by trusted Linux jobs are built and published only
from trusted `main`, manual-main, or release workflows. Signed releases require
an owner-created `v*` tag whose version matches `VERSION` and whose commit is
reachable from `main`; no untrusted workflow receives signing material or can
publish a release.

Adding a collaborator does not automatically make that collaborator trusted to
execute pull-request code on the self-hosted machines. Their PRs continue to use
GitHub-hosted runners. Once code is accepted onto the blessed `main` branch it is
trusted, regardless of its original author.

## Terminal-specific trust boundaries

Terminal applications can intentionally emit control sequences that affect the
window, clipboard, and rendered output. Grimalkin defaults to OSC 52 **Write
only**, which permits terminal applications to set the local clipboard but not
query it. Enabling **Read/write** lets a terminal application—including one
running over SSH—query the local system clipboard. Grimalkin exposes Blocked,
Write only, and Read/write policies under **Copy & paste**; use Read/write only
when every local and remote program in the session is trusted.
