## Codez 0.169.1-r1

- Integrate the complete upstream Codex 0.169.1 release, including GPT-6.2 Sol and Astra model catalogs, provider updates, project trust fixes, SQLite 3.54, and session/MCP lifecycle fixes.
- Bundle and validate the standalone `codex-exec-server` alongside the private `codez-code-mode-host` on macOS and Linux ARM64/x86_64.
- Remove patched zsh packaging and use process-aware release cleanup in both Codez installers. Preserve running releases and refuse to overwrite an installed version with different contents.
- Preserve offline Responses API bootstrap and independent Codez CLI/daemon packages and state directories.

## Codez 0.159.2-r3

- Rename the Code Mode helper executable to `codez-code-mode-host` across builds, runtime lookup, packages, and installers.
- Update online and offline installation examples for this revision.

The changelog can be found on the [releases page](https://github.com/openai/codex/releases).

## Unreleased

- Fix missing command lifecycle events when unified exec cannot create a process, preserving approval rejection and sandbox retry behavior. Thanks @Marvinthebored ([#44557](https://github.com/openai/codex/issues/44557)).
