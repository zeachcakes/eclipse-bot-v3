---
status: accepted
date: 2026-10-20
decision-makers: Kanishk Gupta
---

# Continuous integration and repository automation

## Context and Problem Statement

Nothing checks a pull request before it is merged. The pre-commit hooks run only on machines that installed them, and nothing runs the build and the tests. The build also needs generated jOOQ sources, which need a migrated database ([ADR 0007](0007-per-service-database-schemas.md)). Pull requests get no labels, so the pull request list does not show which parts of the repository each one touches. Pinned versions only change when someone bumps them by hand.

These are the repository's first GitHub Actions workflows. What runs on pull requests and on `main`, how are pull requests labeled, what keeps dependencies current, and what rules do workflows follow?

## Considered Options

* GitHub Actions workflows for CI, the title check and labels, with Dependabot for updates, and CodeQL default setup and zizmor for security.
* Labels for the Conventional Commit type in the title, instead of or next to path labels.
* One third-party labeler, such as `srvaroa/labeler`.
* Renovate instead of Dependabot.
* An advanced CodeQL workflow instead of default setup.
* A PostgreSQL service container in the build job instead of `compose.yaml`.
* The title check as a job in the CI workflow.

## Decision Outcome

Chosen option: "GitHub Actions workflows with Dependabot, CodeQL default setup and zizmor", because it uses GitHub's own services where they exist, and CI runs the same tools and commands as a local checkout.

* Pull request titles already follow Conventional Commits, for example `feat(gradle): Added convention plugins. Part-Of: #16`, so a type label repeats the title. `actions/labeler` cannot read titles, so type labels also need a custom script. Two kinds of labels, such as `type: docs` and `area: docs`, are also harder to tell apart.
* A single third-party labeler would run another publisher's code in a job that holds a write token.
* Renovate also updates mise tools, but it is a third-party app with write access to the repository.
* An advanced CodeQL workflow is one more file with pins to maintain. Default setup analyzes Java without a build, so it needs no database.
* A service container repeats the PostgreSQL image digest from `compose.yaml`, and the two copies could drift.
* A title check needs the `edited` event. In the CI workflow, a title edit would either rerun the build, or show the build jobs as skipped, which hides a failed build.

### Rules for every workflow

* Pin each action to a full commit SHA and put its version in a comment, as in `uses: actions/labeler@<sha> # v7.0.0`. Dependabot updates the pins.
* Set `permissions: {}` at the top of the workflow, and give each job only the permissions it needs.
* Use `pull_request_target` only in a job that never checks out or runs the pull request's code. Never put text that a pull request author controls, such as `${{ github.event.pull_request.title }}`, into a script. Read it from the event payload inside the script.
* In a workflow with a `pull_request_target` trigger, give every job an `if:` on `github.event_name`, so a job that checks out code never runs on that trigger.
* Run jobs on a named runner image, such as `ubuntu-24.04`, not `ubuntu-latest`.
* `actionlint`, `yamlfmt` and zizmor check workflows in pre-commit.

### CI workflow

`.github/workflows/ci.yml` runs on every pull request and on every push to `main`. A new push to a pull request cancels the run in progress.

* The `lint` job installs the hook tools from `mise.lock` with `jdx/mise-action`, then runs `pre-commit run --all-files`. It installs only the tools that the hooks need. Ruby compiles from source, and no hook uses it.
* The `build` job installs Java from `mise.lock`, so Gradle runs on the pinned JDK instead of the runner's default one. `gradle/actions/setup-gradle` caches Gradle and validates the wrapper checksum.
* The `build` job starts PostgreSQL from `compose.yaml` with random, masked passwords that exist only for the job. It creates the `catalog` schema and its migration role, runs `prepareSchema`, then runs `./gradlew build` and the convention plugin check. No credential is in a tracked file or on a command line.

### Pull request title

`.github/workflows/pr-title.yml` fails a pull request whose title is not a Conventional Commit, with `amannn/action-semantic-pull-request`. It accepts the standard types, an optional scope and any subject.

### Pull request labels

* Each label names a part of the repository. A pull request gets every label whose paths it changes, so it can get several labels or none.
* So far the labels are `build`, `database`, `catalog`, `libraries`, `documentation`, `tooling`, `ci` and `dependencies`. `.github/labeler.yml` holds their path rules. A new service gets its own label.
* `documentation` is GitHub's default label, reused for documentation paths. `dependencies` is the label that Dependabot pull requests get. GitHub's other default labels stay as they are, for issues.
* `.github/workflows/labels.yml` has two jobs, and each runs only for its own events with its own permissions. The `label` job runs `actions/labeler` with `sync-labels` on `pull_request_target`, so a label goes away when the pull request stops touching its paths. The `sync` job applies `.github/labels.yml`, which defines the name, color and description of each label, with `crazy-max/ghaction-github-labeler` on a push to `main` that changes the file or the workflow, and on a manual run.
* The sync runs with `skip-delete`, so a label missing from the file is kept. Deleting a label removes it from every issue and pull request, so delete labels by hand, or rename them with `from_name`.
* `pull_request_target` takes the workflow and `.github/labeler.yml` from `main`. Changes to either apply only after they are merged, and the pull request that changes them is labeled by the version on `main`.

### Dependabot

`.github/dependabot.yml` updates the action pins, Gradle (the version catalog and the wrapper), the PostgreSQL image in `compose.yaml`, and the pre-commit hook revision.

* Each ecosystem gets one grouped pull request a week. Releases younger than seven days are skipped, because they are the likeliest to be broken or malicious.
* Titles start with `chore(deps):`, so they pass the title check, and the pull requests get the `dependencies` label.
* Dependabot does not support mise, so the tools in `mise.toml` are still updated by hand.

### Security scanning

* CodeQL runs with GitHub's default setup, which is a repository setting with no workflow file. It analyzes the Java code and the workflows on pull requests, on pushes to `main`, and weekly.
* zizmor checks the workflows and the Dependabot configuration for insecure patterns. It is a pre-commit hook, so it runs locally and in the `lint` job. It runs offline, so it needs no token.
* An accepted zizmor finding gets an inline `# zizmor: ignore[<audit>]` comment with the reason, as on the `pull_request_target` trigger of the labels workflow.

### Consequences

* Good, because every pull request is linted, built and tested before it is merged, with the same tool versions as a local checkout.
* Good, because every pull request shows which parts of the repository it touches, without manual work.
* Good, because action pins, Gradle versions and the database image get update pull requests.
* Good, because label names, colors and descriptions are reviewed in pull requests and can be recreated.
* Good, because insecure workflow patterns fail locally, before they are pushed.
* Bad, because the build job needs Docker and a database, so it is slower than a plain Gradle build.
* Bad, because a new label goes in two places: `.github/labels.yml` and `.github/labeler.yml`.
* Bad, because a label change cannot be previewed before it is merged.
* Bad, because CodeQL default setup is a repository setting, so changes to it are not reviewed in pull requests.
* Bad, because the mise tools still need manual updates.
* Bad, because the title check runs a third-party action.

## More Information

* Files: [CI workflow](../../.github/workflows/ci.yml), [pull request title workflow](../../.github/workflows/pr-title.yml), [labels workflow](../../.github/workflows/labels.yml), [labels](../../.github/labels.yml), [path rules](../../.github/labeler.yml), [Dependabot configuration](../../.github/dependabot.yml) and [pre-commit configuration](../../.pre-commit-config.yaml).
* To repeat the `build` job locally against a throwaway database, use a separate `GRADLE_USER_HOME`. Settings in `~/.gradle/gradle.properties` win over environment variables (ADR 0007), so they would point the job at the development database.
* Actions: [jdx/mise-action](https://github.com/jdx/mise-action/blob/v5.2.1/README.md), [gradle/actions setup-gradle](https://github.com/gradle/actions/blob/v6.4.0/docs/setup-gradle.md), [amannn/action-semantic-pull-request](https://github.com/amannn/action-semantic-pull-request/blob/v6.1.1/README.md), [actions/labeler](https://github.com/actions/labeler/blob/v7.0.0/README.md) and [crazy-max/ghaction-github-labeler](https://github.com/crazy-max/ghaction-github-labeler/blob/v6.0.0/README.md).
* GitHub documentation: [`pull_request_target`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target), [secure use of GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use), [Dependabot options](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference) and [code scanning setup](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/configure-code-scanning/configure-code-scanning).
* [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) and the [zizmor documentation](https://docs.zizmor.sh/).
