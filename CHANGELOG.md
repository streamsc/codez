## Codez 0.159.2-r3

- Rename the Code Mode helper executable to `codez-code-mode-host` across builds, runtime lookup, packages, and installers.
- Update online and offline installation examples for this revision.

The changelog can be found on the [releases page](https://github.com/openai/codex/releases).

## Unreleased

- Fix missing command lifecycle events when unified exec cannot create a process, preserving approval rejection and sandbox retry behavior. Thanks @Marvinthebored ([#44557](https://github.com/openai/codex/issues/44557)).
