# Codex Account Menu · Codex账号

一个 macOS 原生菜单栏工具，用来管理 Codex 的多个 ChatGPT 登录，切换 ChatGPT 与已配置的 Copilot API 来源，并查看各自额度及最近 API 活动。

**适合需要在多个账号或两种推理来源之间切换、又希望保留原有 Codex 配置的用户。** 它不提供账号、API 密钥或公共代理，也不替代 Codex 客户端。

## 能做什么

| 功能 | 实际行为 |
|---|---|
| 多账号管理 | 添加或导入 ChatGPT 登录，重命名账号、移除本工具保存的副本 |
| 来源切换 | 在 ChatGPT 账号和已有 Copilot API 入口之间切换；确认后正常退出并重开 Codex |
| 官方身份保留 | 使用 Copilot 推理时保留所选 ChatGPT 身份，并分别显示“推理来源”和“官方身份” |
| 切回上次 | 恢复上次完整的来源＋身份组合，例如 Copilot＋账号 A |
| 分开查看额度 | ChatGPT 周额度、接口提供的短时窗口，以及可选的 Copilot 本期额度；保留旧数据时间与错误状态 |
| 菜单栏与登录自启 | 在菜单栏打开账号面板，使用 macOS 原生登录项控制自启 |
| 最近 API 活动 | 在主面板显示本机转发状态、活动连接及已采集记录的时间 |
| 对话预览 | 搜索最近本地任务，按需查看有限的 Prompt 与回答，可复制；不建立另一套聊天数据库 |
| 切换恢复保护 | 处理来源锁、活动写入者、原子写入、失败回退和跨小 App 重启保留的未完成状态 |

### “推理来源”和“官方身份”有什么区别

| 选择 | 模型请求发往 | 用于官方身份识别的登录 |
|---|---|---|
| ChatGPT 账号 A | 官方模型入口 | 账号 A |
| ChatGPT 账号 B | 官方模型入口 | 账号 B |
| Copilot＋账号 A | 你已经部署的 Copilot 代理 | 账号 A |
| Copilot，无可用官方身份 | 你已经部署的 Copilot 代理 | 明确显示未连接 |

保留官方身份为需要账号的原生功能提供认证条件，但**不保证所有插件、浏览器、连接器或 Remote 功能都可用**。显示账号名称也不能证明某次请求的计费归属。

## 开始使用

### 环境要求

- macOS 14 或更新版本；当前发布附件为 Apple Silicon 构建。
- 已安装可被本工具识别的 Codex 桌面客户端。当前桌面退出/重开适配默认核对 `/Applications/ChatGPT.app` 与 `com.openai.codex`；客户端路径或标识不同，需先适配 `MacDesktopController`，不要靠改名绕过核验。
- 本机 Node.js 与 Python 3。当前 relay 查找 `/opt/homebrew/bin/node`，不会替你安装运行时。
- 当前 ChatGPT 账号查询/登录子进程在没有显式代理设置时使用本机 `127.0.0.1:7897`。没有该代理时需先适配网络设置；这也影响只使用 ChatGPT 账号的场景，详见 [网络说明](docs/copilot-setup.md#本机账号查询的网络)。
- 源码构建需要 Swift 6.2+ 及 Xcode 或 Command Line Tools。
- 只有使用 Copilot 时才需要自行准备兼容代理；Copilot 额度还需要可选的 SSH 采集配置，见 [接入说明](docs/copilot-setup.md)。

### 安装

在 [Releases](https://github.com/treerobin06/codex-account-menu/releases) 下载适用的 App 压缩包，或从源码构建。当前产物使用 ad-hoc 签名，尚未进行 Developer ID 签名及 Apple 公证。

```sh
git clone https://github.com/treerobin06/codex-account-menu.git
cd codex-account-menu/apps/codex-account-menu
bash scripts/build-app.sh release
bash scripts/install-app.sh release --check
bash scripts/install-app.sh release
open "$HOME/Applications/Codex Account Menu.app"
```

构建只产生 App；安装器不会替你关闭正在运行的程序。安装前先退出旧的小工具，主 Codex 可以保持运行。安装路径默认位于当前用户的 `~/Applications`，旧 App 备份保存在本工具的私有数据目录中。

### 第一次切换

1. 打开菜单栏面板，选择“导入当前登录”，或“添加 ChatGPT 账号”完成官方登录。
2. 点击目标账号卡片；需要 API 时，先完成 Copilot 接入，再选择 Copilot。
3. 阅读来源、身份及回退说明，确认后正常退出并重开 Codex。**这会结束当前桌面任务，请先保存尚未发送的输入。**
4. 重开后查看“推理来源”和“官方身份”。需要恢复时，选择“切回上次”或另一个已保存账号。

默认只改登录、模型入口及本工具自己的状态。Skills、MCP、Plugins、提示词和其他配置区域保持原有内容；默认不迁移或改写历史对话。

## 额度与最近活动怎么读

- **额度**是对应上游接口的快照，不推算剩余请求次数、Token、金额或可用时长。未提供某个窗口时不伪造；获取失败会标明旧数据的时间。
- **API 转发已启用**表示本机转发开关已开启，不代表远端代理可达；**逐对话记录待启用**表示旧 helper 尚未启用记录，不能据此断定请求走了官方额度。
- 一条 WebSocket 可以承载多轮问答。连接建立、HTTP 200 或握手成功，不等于回答完成或扣费确认。
- 当前仅保留有界的内存传输元数据；helper 重启后记录清空。对话预览按需读取本地文件片段，只展示用户/助手消息；片段内的推理、系统或工具条目会被过滤，不进入预览。

## 已知限制

- 当前来源集成针对 ChatGPT 与 Copilot，**不是任意 API 服务的通用配置管理器**。
- 旧对话的密文、模型与自定义 provider 可能不兼容新来源。切换默认入口不会迁移全部历史；无法续聊时可能需要新建任务。
- 正常退出被拒绝、共享配置仍有写入者或恢复未完成时，切换会停止并保留提示；不会强杀第三方应用来绕过检查。
- 账号/额度接口与桌面客户端可能变化；API 模式下各项官方功能需要独立验证。
- 日常刷新不会升级正在服务其他连接的 relay；升级沿用正常切换和空闲检查流程。

更多说明：[使用与恢复](apps/codex-account-menu/README.md) · [验证范围](apps/codex-account-menu/VALIDATION.md) · [开发与测试](docs/development.md) · [隐私与本地数据](PRIVACY.md)。

## 项目结构与来源

`apps/codex-account-menu` 是菜单栏 App、CLI 和本机 relay；`init/copilot-proxy` 是可选的上游代理适配及传输示例。普通账号切换不需要部署全部服务器组件。

部分核心来自 MIT 许可的开源项目；上游版本、版权声明及当前许可范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [UPSTREAM.md](apps/codex-account-menu/UPSTREAM.md)。
