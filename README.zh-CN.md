# Codez

[English](README.md) | [简体中文](README.zh-CN.md)

Codez 基于开源项目 [OpenAI Codex CLI](https://github.com/openai/codex)，并与上游保持兼容。它保留 Codex 的内部实现和本地数据格式，同时以 `codez` 的名称对外提供产品。

Codez 跟踪上游 Codex 版本，并为 macOS Apple Silicon 以及 Linux x86_64/ARM64 发布未签名的软件包。

## 主要特点

- 与上游 Codex 保持兼容，共享配置、认证信息、本地会话和其他数据格式。
- 支持 macOS Apple Silicon、Linux x86_64 和 Linux ARM64。
- 提供多平台离线安装包，为无网络、受限网络或隔离环境提供安装支持。

## 安装

```shell
curl -fsSL https://github.com/streamsc/codez/releases/latest/download/install-codez.sh | sh
codez
```

安装程序会自动检测当前平台，并下载以下发布包之一：

- `codez-package-aarch64-apple-darwin.tar.gz`
- `codez-package-x86_64-unknown-linux-musl.tar.gz`
- `codez-package-aarch64-unknown-linux-musl.tar.gz`

安装程序支持现有的 Codex 环境变量：

- `CODEX_HOME` 用于指定共享的配置和会话目录（默认为 `~/.codex`）。
- `CODEX_INSTALL_DIR` 用于指定公共命令目录（默认为 `~/.local/bin`）。
- `CODEX_RELEASE` 用于固定安装特定版本，例如 `codez-v0.144.4-r1`。

### 离线安装

每个 Codez 版本还会发布一个多平台离线包。将 `codez-offline-vX.Y.Z-rN.tar.gz` 和
`codez-offline-bundle_SHA256SUMS` 复制到离线设备，验证外层离线包的校验和，然后解压：

```shell
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c codez-offline-bundle_SHA256SUMS
else
  shasum -a 256 -c codez-offline-bundle_SHA256SUMS
fi
tar -xzf codez-offline-v0.144.4-r9.tar.gz
./codez-offline-v0.144.4-r9/install-codez-offline.sh \
  --bundle ./codez-offline-v0.144.4-r9
```

离线安装程序会选择对应的 macOS Apple Silicon、Linux x86_64 或 Linux ARM64 软件包，
根据包内的 SHA-256 记录进行校验，并在不连接 GitHub 的情况下完成安装。它支持与在线安装程序相同的
`CODEX_HOME` 和 `CODEX_INSTALL_DIR` 环境变量。

如果需要在安装时直接配置内网 OpenAI 兼容 Responses API，并跳过首次启动的登录界面，
可传入完整 API 根地址和 API Key：

```shell
./codez-offline-v0.144.4-r9/install-codez-offline.sh \
  --bundle ./codez-offline-v0.144.4-r9 \
  --api-base-url https://gateway.internal/v1 \
  --api-key sk-internal \
  --model internal-model
```

`--model` 可选。安装器只校验 URL 格式，不会连接内网服务；它会保留
`CODEX_HOME/config.toml` 中的其他设置，并通过 Codez 正常的 API Key 登录流程存储密钥，
不会将密钥写入 `config.toml`。内网服务必须在 `{api-base-url}/responses` 提供 Responses API；
仅支持 Chat Completions 的网关不能使用。HTTP 地址仍可配置，但安装器会警告 API Key 将以未加密方式传输。

配置成功后，Codez 会将地址写入 `openai_base_url`，选择内置的 `openai` provider；只有传入
`--model` 时才会写入默认模型。已有的模型推理设置和其他 TOML 配置会保持不变。认证存储方式
遵循 `cli_auth_credentials_store`，因此 Codez 与 Codex 共用 `CODEX_HOME` 时会使用同一份认证信息。

通过 `--api-key` 传入密钥可能使它出现在 shell 历史和进程列表中。安装器不会回显密钥，
也不会将密钥放入子 Codez 进程的命令行。由于 Codez 和 Codex 共享 `CODEX_HOME`，
两者使用同一目录时都会读取这些 API 配置和认证。

## Codex 兼容性与共存

Codez 有意与 Codex 共享以下内容：

- `CODEX_HOME` 和 `.codex`
- 身份验证信息和钥匙串条目
- 配置、运行会话、记忆、技能、插件和 SQLite 状态
- 内部 crate、协议、模型标识和 `CODEX_*` 环境变量

可能影响共存的文件会单独存放：

- 软件包：`$CODEX_HOME/packages/codez/`
- 更新元数据：`$CODEX_HOME/codez/version.json`
- 日志：`codez-tui.log` 和 `codez-login.log`
- app-server 守护进程的套接字、PID 和锁目录使用 `codez-*` 名称

主进程名为 `codez`。Code Mode 可能会启动名为 `codex-code-mode-host` 的子进程；该辅助程序保留上游名称，
并与真正的 Codez 二进制文件一起位于 Codez 私有发布目录中。它不会被链接到公共 PATH，因此不会覆盖已安装的
Codex 辅助程序。

## 开发

`main` 分支专用于跟踪上游。产品变更位于 `codez` 分支，该分支应设为仓库的默认分支。

内部 Cargo 二进制目标仍名为 `codex`：

```shell
cd codex-rs
cargo build --bin codex --bin codex-code-mode-host
```

构建 Codez 软件包目录结构时，请选择 Codez 软件包变体：

```shell
CODEZ_VERSION=0.144.4-r1 python3 scripts/build_codex_package.py \
  --variant codez \
  --target aarch64-apple-darwin \
  --cargo-profile release \
  --package-dir dist/codez-package \
  --archive-output dist/codez-package-aarch64-apple-darwin.tar.gz
```

Linux 版本使用 musl，并包含内置的 `bwrap`。请先构建 `bwrap`，确定其最终二进制内容，再将摘要传给 Codez 构建流程：

```shell
TARGET=x86_64-unknown-linux-musl
cd codex-rs
cargo build --target "$TARGET" --release --bin bwrap
strip --strip-debug --strip-unneeded "target/$TARGET/release/bwrap"
export CODEX_BWRAP_SHA256="$(sha256sum "target/$TARGET/release/bwrap" | awk '{print $1}')"
cd ..
CODEZ_VERSION=0.144.4-r1 python3 scripts/build_codex_package.py \
  --variant codez \
  --target "$TARGET" \
  --cargo-profile release \
  --bwrap-bin "codex-rs/target/$TARGET/release/bwrap" \
  --package-dir "dist/codez-package-$TARGET" \
  --archive-output "dist/codez-package-$TARGET.tar.gz"
```

标签格式为 `codez-v<上游版本>-r<N>`，例如 `codez-v0.144.4-r1`。发布工作流会构建三个平台的软件包，
发布统一的校验和清单，并在不同运行之间缓存 Cargo 依赖和编译器输出。定时上游同步工作流会检测稳定的
`rust-vX.Y.Z` 标签并创建供审核的 PR，但不会自动合并。

## 上游文档

Codez 的配置和行为与 Codex 保持兼容，因此 [Codex 文档](https://developers.openai.com/codex) 仍是主要的使用参考。

本仓库采用 [Apache-2.0 许可证](LICENSE)。
