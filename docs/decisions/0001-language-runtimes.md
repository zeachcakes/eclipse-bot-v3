---
status: accepted
date: 2026-09-23
decision-makers: Kanishk Gupta
---

# Language runtimes: Java, Python and Node.js for the bot, Ruby for dev tooling

## Context and Problem Statement

The repository pins its development tools with mise. Until now it pinned no language runtime, because choosing one is the stack decision for the bot. Adding linters, formatters and pre-commit needs runtimes, and the bot itself needs a base stack. Which runtimes do we pin, and what is each one for?

## Decision Outcome

Pin four runtimes in `mise.toml`:

| Runtime | Version            | Role                             |
|---------|--------------------|----------------------------------|
| Java    | Temurin 25 (LTS)   | Base stack for the bot           |
| Python  | 3.14               | Base stack for the bot           |
| Node.js | 24 (LTS)           | Base stack for the bot           |
| Ruby    | 4.0                | Dev tooling only, not in the bot |

Java and Node.js follow their LTS lines. Exact versions and checksums live in `mise.toml` and `mise.lock`.

Ruby exists for tools and pre-commit hooks that need it. Bot code must not depend on Ruby.

### Consequences

* Good, because every contributor and CI job gets the same runtime versions from `mise install`.
* Good, because Python is also available to Python-based tools such as `pipx` and `pre-commit`.
* Bad, because three bot runtimes mean three toolchains to build, test and keep current.
* Open: this ADR does not decide which parts of the bot use which runtime. It also does not choose frameworks or a datastore. Record those in later ADRs.
* Adding, removing or changing the role of a runtime needs a new ADR that supersedes this one.
