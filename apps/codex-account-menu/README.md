# 使用与恢复

功能总览、环境要求和安装方法见 [项目首页](../../README.md)。本页说明账号操作、本地数据与失败恢复。

## 账号操作

- **添加账号**：通过官方登录流程添加 ChatGPT 登录；添加成功只保存账号，不自动切换。取消登录保持可用。
- **导入当前登录**：将当前 Codex 登录保存到列表；原生登录发生变化后可重新导入。
- **点击账号卡片**：先显示确认，再正常退出/重开 Codex，选择该账号作为官方身份和推理来源。
- **选择 Copilot**：使用已经配置的代理，尽量沿用并核验当前官方身份；右侧菜单可一次选择已保存身份。
- **切回上次**：恢复完整来源和身份组合，包含明确记录的“没有官方身份”状态。
- **移除账号**：移除本工具保存的副本，不撤销远端授权；正在使用的副本受到保护。
- **登录自启**：使用原生登录项。系统显示“等待允许”时，需在系统设置中批准后才算启用。

额度刷新期间仍可选择来源；最终操作会等待自有读取任务释放共享锁。安装、普通刷新和启动恢复不会自行退出主 Codex。

## 对话与活动

主面板显示最近 API 活动，点击可进入“对话与请求”。最近最多读取 100 项本地任务索引；预览先读选中记录尾部 512 KiB，必要时扩大到 4 MiB，最多显示 12 条公开用户/助手消息、每条 2000 字符。超出的内容仍需在原客户端查看。

传输记录使用请求自带的 `thread-id` 精确关联，不用标题、时间、共享 `session-id` 或当前登录猜测来源。没有匹配证据就显示未核验；本功能不是账单审计器。

## 本地文件

默认数据目录为 `~/Library/Application Support/Codex Account Menu/`，默认 Codex 配置目录为 `~/.codex`。

| 文件或目录 | 用途 |
|---|---|
| `accounts.json` / `accounts/` | 账号索引及敏感登录副本 |
| `home-binding.json` | 绑定一个规范化的 Codex 配置目录，避免多个 home 串用账号库 |
| `usage-cache.json` | 最近成功额度与获取时间 |
| `previous-source.json` | 上次完整的来源和身份组合 |
| `switch-pending.json` | 未完成切换标记；重开小工具仍保留 |
| `credential-recovery/` | 验证失败后需保留核验的凭据副本 |
| `app-backups/` | 安装时保留的旧 App |
| `api-relay/` | 本机私有控制 socket 与 helper 状态 |

这些目录不属于源码，不应提交 Git 或作为普通诊断附件分享。详细数据边界见 [PRIVACY.md](../../PRIVACY.md)。

## 恢复操作

优先打开菜单栏工具，选择“切回上次”，或选择另一个真实保存的 ChatGPT 账号。界面会提供正常退出和回退说明。

```sh
cli="$HOME/Applications/Codex Account Menu.app/Contents/Helpers/codex-menu"
"$cli" status
"$cli" back --restart
```

`back --restart` 会结束当前桌面任务。可先用 `plan` 查看目标：

```sh
"$cli" plan copilot
"$cli" plan copilot --identity ACCOUNT_UUID
```

恢复未完成时，保留错误提示和 `switch-pending.json`，先核对它标识的状态；不要通过删除锁、绑定记录或 pending 文件让程序继续写入。未知配置变化会阻止自动覆盖。

切回原生请通过本工具完整恢复入口与账号；仅修改 `model_provider=openai` 不足以保证退出 API 模式，因为 `openai_base_url` 可能仍指向本机 relay。不要整份覆盖旧 `config.toml`，以免丢掉之后的其他修改。

## CLI

| 命令 | 行为 |
|---|---|
| `status` / `list` | 查看本地来源与账号列表 |
| `account` / `usage` | 查询并核对官方身份或额度 |
| `runtime-auth` | 按实际配置查询官方身份，不用强制 OpenAI 查询代替混合配置验证 |
| `copilot` | 获取可选的 Copilot 额度快照 |
| `import-current` | 保存当前原生登录 |
| `plan copilot\|ACCOUNT_UUID` | 检查目标组合，不执行切换 |
| `switch copilot --restart` | 正常退出/重开并切到 Copilot |
| `switch copilot --identity ACCOUNT_UUID --restart` | 一次切换来源和指定身份 |
| `switch ACCOUNT_UUID --restart` | 正常退出/重开并切到指定 ChatGPT 账号 |
| `back --restart` | 恢复上次组合 |
| `maintain-relay` | 在受管理配置、正确绑定且无未完成切换时恢复缺失 helper；不退出桌面 |

支持 `--home PATH`、`--state PATH`、`--codex PATH`。自定义 home 应使用独立账号库，不能通过删除绑定规避校验。`--isolated` 只用于明确的临时测试目录。

## 构建与安装

```sh
bash scripts/test.sh
bash scripts/build-app.sh release
bash scripts/install-app.sh release --check
bash scripts/install-app.sh release
```

构建产物默认位于 `~/Library/Caches/Codex Account Menu/build/release/`。安装器校验应用身份、签名、目标所有权和符号链接，拒绝覆盖同名无关应用；安装失败会给出保留的旧版位置。它不会替你关闭任何正在运行的应用。
