# `rusty_v8` Consumer Artifacts

Codez release builds consume the matching sandbox-enabled `rusty_v8` archive
and source binding from the upstream `openai/codex` release. The release
workflow resolves the crate version from `codex-rs/Cargo.lock` and configures
both files through `.github/actions/setup-rusty-v8`.

Current pinned versions:

- Rust crate: `v8 = =150.4.0` (`rusty-v8-v150.4.0` release assets)
- Embedded upstream V8 source for Bazel-produced builds: `15.0.245.2`

The `ptrcomp_sandbox_release` archive and binding must match the exact resolved
`v8` crate version and its sandbox/pointer-compression features. Downloads are
verified against the release manifest, whose SHA-256 is pinned in
`rusty_v8_150_4_0_release_manifests.sha256`. Local package builds apply the same
verification through `scripts/codex_package/v8.py`.

Bazel selects published Darwin/GNU inputs or source-built musl/Windows GNU
inputs through `MODULE.bazel`. When updating the pinned version, update and
independently verify the manifests before refreshing the Bazel entries:

```bash
python3 .github/scripts/rusty_v8_bazel.py update-module-bazel
python3 .github/scripts/rusty_v8_bazel.py check-module-bazel
```

Codez consumes these upstream artifacts; this repository does not publish V8
artifacts or run the upstream V8 release workflow.
