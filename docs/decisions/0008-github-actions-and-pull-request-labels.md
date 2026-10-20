---
status: accepted
date: 2026-10-20
decision-makers: Kanishk Gupta
---

# GitHub Actions workflows and pull request labels

## Context and Problem Statement

Pull requests get no labels, so the pull request list does not show which parts of the repository each one touches. Labeling by hand is easy to forget.

The repository has no GitHub Actions workflows yet, so the labeler is also the first workflow. Which labels do pull requests get, what applies them, and what rules do workflows follow?

## Considered Options

* Labels for the changed paths, applied by `actions/labeler`, with label definitions in a file that the same workflow syncs.
* Labels for the Conventional Commit type in the title, applied by a script.
* Both kinds of labels, as `area:` and `type:` labels.
* One third-party labeler, such as `srvaroa/labeler`.
* Separate workflows for labeling pull requests and for syncing labels.
* Labels added by hand.

## Decision Outcome

Chosen option: "Labels for the changed paths, applied by `actions/labeler`", because such a label shows something that the pull request title does not, and the workflow needs no custom code.

* Pull request titles already follow Conventional Commits, for example `feat(gradle): Added convention plugins. Part-Of: #16`, so a type label repeats the title. Every pull request so far would get `feat`. `actions/labeler` cannot read titles, so type labels also need a custom script.
* Two kinds of labels are harder to tell apart, for example `type: docs` and `area: docs`.
* A single third-party labeler would run another publisher's code in a job that holds a write token.
* Separate workflows add a file for each job of one concern. One workflow keeps the same isolation, because each job has its own event condition and permissions.
* Labels added by hand depend on remembering to add them.

### Labels

* Each label names a part of the repository. A pull request gets every label whose paths it changes, so it can get several labels or none.
* So far the labels are `build`, `database`, `catalog`, `libraries`, `documentation`, `tooling`, `ci` and `dependencies`. `.github/labeler.yml` holds their path rules. A new service gets its own label.
* `documentation` is GitHub's default label, reused for documentation paths. `dependencies` is the name that Dependabot uses. GitHub's other default labels stay as they are, for issues.

### Workflow

`.github/workflows/labels.yml` has two jobs. Each job runs only for its own events and has its own permissions.

* The `label` job runs on `pull_request_target` when a pull request is opened, reopened or pushed to. It runs `actions/labeler` with `sync-labels`, so a label goes away when the pull request stops touching its paths.
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

* Good, because every pull request shows which parts of the repository it touches, without manual work.
* Good, because label names, colors and descriptions are reviewed in pull requests and can be recreated.
* Good, because the workflow has no custom code.
* Bad, because labels do not show the kind of change. Only the Conventional Commit type in the title does.
* Bad, because a new label goes in two places: `.github/labels.yml` and `.github/labeler.yml`.
* Bad, because a label change cannot be previewed before it is merged.
* Bad, because pinned actions never update themselves. Someone has to bump them.

## More Information

* Files: [labels](../../.github/labels.yml), [path rules](../../.github/labeler.yml) and [workflow](../../.github/workflows/labels.yml).
* Actions: [actions/labeler](https://github.com/actions/labeler/blob/v7.0.0/README.md) and [crazy-max/ghaction-github-labeler](https://github.com/crazy-max/ghaction-github-labeler/blob/v6.0.0/README.md).
* [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
* GitHub documentation: [`pull_request_target`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target) and [secure use of GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use).
