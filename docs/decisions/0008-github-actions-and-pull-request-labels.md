---
status: accepted
date: 2026-10-20
decision-makers: Kanishk Gupta
---

# GitHub Actions workflows and pull request labels

## Context and Problem Statement

Pull requests get no labels, so the pull request list does not show what kind of change each one is or which parts of the repository it touches. Labeling by hand is easy to forget. Pull request titles already follow Conventional Commits, for example `feat(gradle): Added convention plugins. Part-Of: #16`, and branches are named like `feature/...`.

The repository has no GitHub Actions workflows yet, so the labeler is also the first workflow. Which labels do pull requests get, what applies them, and what rules do workflows follow?

## Considered Options

* `actions/labeler` for paths, an inline `actions/github-script` step for the type, and label definitions in a file that a workflow syncs.
* One third-party labeler, such as `srvaroa/labeler`, for paths, titles and branches.
* `actions/labeler` `head-branch` rules for the branch prefix, next to a separate title step.
* Labels added by hand.
* Separate workflows for labeling pull requests and for syncing labels.

## Decision Outcome

Chosen option: "`actions/labeler` for paths, an inline `actions/github-script` step for the type", because both actions come from GitHub, and one step owns the type labels.

* A single third-party labeler would run another publisher's code in a job that holds a write token.
* `actions/labeler` cannot read the title. If `head-branch` rules and a title step both set `type:` labels, they undo each other. On branch `feature/x` with the title `fix: ...`, the title step removes `type: feat`, and the next labeler run adds it back.
* Labels added by hand depend on remembering to add them.
* Separate workflows add a file for each job of one concern. One workflow keeps the same isolation, because each job has its own event condition and permissions.

### Labels

* `type: <type>`: at most one per pull request, for the Conventional Commit types `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore` and `revert`. The type comes from the title. When the title has no known type, it comes from the branch prefix, where `feature` means `feat`, and `bugfix` and `hotfix` mean `fix`.
* `breaking`: the title marks its type with `!`, as in `fix!: ...`.
* `area: <area>`: the pull request changes files in that area. So far the areas are `build`, `database`, `catalog`, `libraries`, `docs`, `tooling` and `ci`. A new service gets its own `area:` label.
* `dependencies`: the pull request changes the version catalog, the Gradle wrapper or `mise.lock`. Dependabot uses the same label name.
* GitHub's default labels stay as they are, for issues.

### Workflow

`.github/workflows/labels.yml` has two jobs. Each job runs only for its own events and has its own permissions.

* The `label` job runs on `pull_request_target` when a pull request is opened, reopened, edited or pushed to. Its first step runs `actions/labeler` with the path rules in `.github/labeler.yml` and `sync-labels`, so an `area:` label goes away when the pull request stops touching that area. Its second step is an `actions/github-script` script that sets the `type:` and `breaking` labels and removes stale ones, so a title edit relabels the pull request.
* The `sync` job applies `.github/labels.yml`, which defines the name, color and description of each label, with `crazy-max/ghaction-github-labeler`. It runs on a push to `main` that changes the file or the workflow, and on a manual run. Label changes apply when they are merged. There is no dry run.
* The sync runs with `skip-delete`, so a label missing from the file is kept, including GitHub's default labels. Deleting a label removes it from every issue and pull request, so delete labels by hand, or rename them with `from_name`.
* `pull_request_target` takes the workflow and `.github/labeler.yml` from `main`. Changes to either apply only after they are merged. The pull request that changes them is labeled by the version on `main`, and the pull request that adds the workflow is not labeled at all.

### Rules for every workflow

* Pin each action to a full commit SHA and put its version in a comment, as in `uses: actions/labeler@<sha> # v7.0.0`. Update the pins by hand, like the PostgreSQL image digest and the Gradle wrapper checksum.
* Set `permissions: {}` at the top of the workflow, and give each job only the permissions it needs.
* Use `pull_request_target` only in a job that never checks out or runs the pull request's code. Never put text that a pull request author controls, such as `${{ github.event.pull_request.title }}`, into a script. Read it from the event payload inside the script.
* In a workflow with a `pull_request_target` trigger, give every job an `if:` on `github.event_name`, so a job that checks out code never runs on that trigger.
* Run jobs on a named runner image, such as `ubuntu-24.04`, not `ubuntu-latest`.
* `actionlint` and `yamlfmt` check workflows in pre-commit.

### Consequences

* Good, because every pull request gets its type and areas without manual work, and a title edit corrects the type.
* Good, because label names, colors and descriptions are reviewed in pull requests and can be recreated.
* Bad, because a new label goes in two places: `.github/labels.yml` and the rule that applies it.
* Bad, because a label change cannot be previewed before it is merged.
* Bad, because pinned actions never update themselves. Someone has to bump them.
* Bad, because a pull request whose title has no Conventional Commit type, on a branch without a known prefix, gets no type label. The run logs a notice instead.

## More Information

* Files: [labels](../../.github/labels.yml), [path rules](../../.github/labeler.yml) and [workflow](../../.github/workflows/labels.yml).
* Actions: [actions/labeler](https://github.com/actions/labeler/blob/v7.0.0/README.md), [actions/github-script](https://github.com/actions/github-script/blob/v9.0.0/README.md) and [crazy-max/ghaction-github-labeler](https://github.com/crazy-max/ghaction-github-labeler/blob/v6.0.0/README.md).
* [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
* GitHub documentation: [`pull_request_target`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target) and [secure use of GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use).
