# Repository instructions

These instructions apply to Codex and Claude when implementing features or
making other changes in this repository. Keep shared guidance in this file;
`CLAUDE.md` imports it so both tools follow the same rules.

## GitHub commit strategy

### Branches

- Work on a dedicated branch for the task, targeting `main` for the pull request.
- Give the branch a descriptive name, such as `feat/discord-clan-commands` or
  `docs/agent-commit-instructions`.
- Inspect `git status` before making changes. Preserve existing work and keep
  unrelated changes out of the task's commits.

### Commit messages

Use Conventional Commits for commit subjects and pull request titles:

```text
<type>(<scope>): <summary>. <issue-reference>
```

- Choose the type for the change: `feat` for a feature, `fix` for a bug fix,
  `docs` for documentation, `refactor` for restructuring without a behavior
  change, `test` for tests, `ci` for CI changes, `build` for build changes, and
  `chore` for maintenance. Conventional Commits also allows `perf`, `style`
  and `revert`.
- Scope is optional. When useful, name the affected area, such as `discord`,
  `gradle`, `postgres`, `github-actions` or `deps`.
- Match the existing human-authored subjects: start the summary with a capital
  letter and describe the concrete change, for example `Added convention
  plugins` or `Removed separate type and area labels`.
- For work tracked by a GitHub issue, append `Part-Of: #<number>` while the
  issue remains incomplete. Use `Closes: #<number>` only when the change
  completes the issue, including its required tests and documentation.
- Keep the issue reference in the subject, as in the existing history. If no
  issue is associated with the task, omit the reference; do not invent one.
- Add a body when the reason, behavior or tradeoff needs explanation. For a
  breaking change, use `!` before the colon and explain the change in a
  `BREAKING CHANGE:` footer.

Examples from the repository history:

```text
feat(gradle): Added convention plugins. Part-Of: #16
feat(postgres): Added postgres docker config. Closes: #12
```

A documentation-only change without an associated issue could use:

```text
docs(agents): Added shared GitHub commit instructions
```

### Commit boundaries and checks

- Keep each commit focused on one coherent change that can be reviewed on its
  own. Include the tests and documentation needed for that change.
- A feature can span several commits. Use `Part-Of` for intermediate work and
  reserve `Closes` for the commit that completes the issue. Do not mark a
  partial implementation as complete.
- Review the diff and stage the intended paths explicitly. Inspect
  `git diff --cached` before committing. Keep credentials, local `.env` files,
  build output and generated jOOQ sources out of commits.
- Commit dependency manifests and their lockfiles together when changing
  dependencies, as described in [ADR 0010](docs/decisions/0010-centralized-development-workflow.md).
- Run the checks relevant to the change using the commands in
  [development guide](docs/development.md). Run the repository hooks with
  `mise exec -- pre-commit run --all-files --show-diff-on-failure` after the
  pinned tools are installed. Review and restage any hook fixes before
  committing. Report checks that could not run and why.

### Pull requests

- Use the same Conventional Commit format for the pull request title. The
  [PR title workflow](.github/workflows/pr-title.yml) checks this; it does not
  validate individual commit messages.
- Describe the resulting behavior, the reason for the change and the checks
  run in the pull request body.
- Use `Part-Of` for a pull request that advances an issue and `Closes` only
  when the pull request completes it. GitHub processes closing keywords when
  the change reaches the default branch; `Part-Of` records the relationship
  without closing the issue.

### Squash, rebase and merge

- A feature branch can contain multiple working commits. Before merging,
  squash the commits for that feature into one commit, including its tests
  and documentation. The result on `main` is one commit for the feature.
- Write the squashed commit message for the complete feature using the
  conventions above. Keep the pull request title aligned with that message.
  Use `Closes` if the feature completes its issue, or `Part-Of` if work on
  that issue remains.
- Rebase the squashed feature commit onto the latest `main`, then merge with
  GitHub's **Rebase and merge** option to keep the history linear. Resolve
  conflicts on the feature branch and rerun relevant checks if conflict
  resolution changes the implementation.

The existing GitHub automation is documented in
[ADR 0008](docs/decisions/0008-continuous-integration-and-repository-automation.md).
