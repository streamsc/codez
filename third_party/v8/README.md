# `rusty_v8` Consumer Artifacts

This directory wires the `v8` crate to exact-version Bazel inputs.

Codez release builds consume the matching `rusty_v8` archive and source binding
from the upstream `openai/codex` release. The release workflow resolves the
crate version from `codex-rs/Cargo.lock` and configures both files through
`.github/actions/setup-rusty-v8`.

Bazel builds select their source-built archives and bindings through
`MODULE.bazel`. When the pinned `v8` version changes, update and validate those
entries with:

```bash
python3 .github/scripts/rusty_v8_bazel.py update-module-bazel
python3 .github/scripts/rusty_v8_bazel.py check-module-bazel
```

The archive and binding must match the exact resolved `v8` crate version.
