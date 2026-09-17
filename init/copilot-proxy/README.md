# 可选的 Copilot 代理适配

本目录提供固定版本上游的补丁、私有监听适配和维护示例。它不是在线服务，也不会给使用者提供账号或授权。仅使用菜单栏工具管理 ChatGPT 账号时不需要部署本目录。

## 组成

| 文件 | 用途 |
|---|---|
| `UPSTREAM` / `LICENSE.upstream` | 上游固定提交与原始 MIT 声明 |
| `github-cli-auth.patch` | 显式使用已有 Copilot CLI OAuth 的兼容路径；默认上游路径仍保留 |
| `launcher.py` / `unix-listener.cjs` | 从 systemd credential 读取授权，运行 Node 并限制为私有 Unix socket |
| `tree-copilot-proxy.service` | Linux 服务示例；需要自行创建服务账号与提供凭据 |
| `health.py` / `tree-copilot-health.*` / `30-recovery.conf` | 健康状态机、退避重试和可选告警示例 |
| `mac-transport/` | 可选的 Mac 私有隧道与恢复示例 |
| `codex-copilot` / `claude-copilot` | 可按环境覆盖路径的专用启动包装 |

## 重建上游

按 `UPSTREAM` 中固定的提交准备源码，先确认补丁可应用：

```sh
git apply --check /path/to/codex-account-menu/init/copilot-proxy/github-cli-auth.patch
git apply /path/to/codex-account-menu/init/copilot-proxy/github-cli-auth.patch
bun install --frozen-lockfile --ignore-scripts
bun run typecheck
bun --bun run build
```

这些命令在上游源码目录执行。上游开发需要其声明的 Bun 版本；发布运行使用 Node。公开附件中的上游源码归档供固定版本复现，不包含依赖缓存。

## 服务示例的前提

示例路径为 `/opt/tree-copilot-proxy`，服务用户和组为 `copilot-proxy`。systemd `LoadCredential` 从 `/etc/copilot-proxy/config.json` 提供 Copilot 配置；这个真实文件必须由部署者自行准备并限制权限，不进入 Git。

可选出站代理凭据使用 `/etc/copilot-proxy/network.env`，需要时才启用 unit 中相应的 `LoadCredential` 行。该示例沿用本机 `127.0.0.1:17998` 出口及 `DIRECT_USER` / `DIRECT_PASS` 字段；不是通用代理自动发现器。告警脚本 `/usr/local/sbin/notify.sh` 也需自行实现或调整，不能把模板存在当成告警已接通。

launcher 中的账号类型示例为 `enterprise`。部署者应按自己的实际授权核对上游兼容性，不要照抄为其他账号类型。模板不创建系统账号、不复制登录、不开放公网端口；Unix socket 权限和 SSH 访问应在自己的主机上单独验收。

普通模型入口与 Mac 接入见 [接入说明](../../docs/copilot-setup.md)。模型目录可达只是基础检查，实际生成、工具调用及所需 WebSocket 路径仍需独立验证。

## 凭据与状态含义

兼容补丁使用已有 OAuth，并定时重新核验。内部 `expires_at` / `refresh_in` 是本地核验安排，不是 GitHub 给出的真实有效期，也不会延长已撤销授权的寿命。

真实凭据留在代理主机。本机使用的 `local` 是占位值；官方 ChatGPT 身份与 Copilot 模型授权是不同路径，不应混用。

## 恢复示例

先查看本地计划：

```sh
python3 deploy-recovery.py plan
```

需要部署时，必须自行提供 SSH 配置、正确目标和 `--expected-hostname`。`apply` / `rollback` 在实际主机检查后才操作，不把参数当作可以打断活动请求的默认授权。

Mac 端回到官方账号使用菜单栏工具的“切回上次”或选择真实保存的账号。不要仅改顶层 provider，也不要恢复已被新入口替代的旧隧道。
