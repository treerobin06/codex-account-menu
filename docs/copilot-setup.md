# 接入已有 Copilot 代理

Copilot 是一个可选推理来源。仅管理 ChatGPT 账号时不需要部署本页组件。这个项目不提供公共代理、GitHub 账号或 Copilot 订阅。

## 模型入口

先自行部署兼容 OpenAI Responses 的 Copilot 代理，并通过 loopback 或已认证的私有隧道使它在本机 `127.0.0.1:4141` 可用。代理维护示例位于 [init/copilot-proxy](../init/copilot-proxy/README.md)，不应直接照抄为公网监听服务。

以下只检查模型目录，不代表一次模型生成已成功：

```sh
curl --fail http://127.0.0.1:4141/v1/models
```

在自己的 Codex 配置中保留既有内容，确认存在以下 provider 段；不要用它覆盖整份配置：

```toml
[model_providers.copilot]
name = "Copilot"
base_url = "http://127.0.0.1:4141/v1"
wire_api = "responses"
supports_websockets = true
requires_openai_auth = true
experimental_bearer_token = "local"
```

`local` 是本机占位值，不是 GitHub 令牌。上游真实凭据应只由你自己的代理持有。使用的模型需要真实出现在你的代理能力范围内，本工具不会替你购买权限或保证任意模型可用。

然后在菜单栏选择 Copilot，阅读确认后正常退出/重开 Codex。App 管理本机 `4142` relay，将模型请求转入已有 `4141` 入口；有可用 ChatGPT 登录时，可以保留其官方身份。App 不会自动部署服务器、安装代理或开放网络端口。

## Copilot 额度（可选）

当前额度采集通过用户自行配置的 SSH 别名 `copilot-server` 运行只读 Python 脚本。你需要提供自己的主机地址、严格主机密钥校验和受信任权限；公开仓库没有真实主机配置。

采集命令使用 `sudo -n python3 -`，面向自管、受信任的维护环境。没有这种环境时可以不配置 SSH 额度采集；模型转发与额度读取是两个路径，读不到额度会显示未取得/旧数据，不应伪造百分比。

远端采集器默认读取执行用户的 `~/.copilot/config.json`；可选出站代理凭据位于 `/etc/copilot-proxy/network.env`。格式和实际存储应由主机管理员审查，不应把真实文件提交仓库。脚本只返回白名单身份/额度字段，凭据不回传 Mac。

## 本机账号查询的网络

桌面启动的应用未必继承终端环境。当前账号查询/登录子进程在没有显式代理设置时使用 `127.0.0.1:7897`；已有显式环境优先，本机地址绕过代理。它不改系统代理。

如果本机没有这一代理入口，应先在 [AccountProxyEnvironment.swift](../apps/codex-account-menu/Sources/SwitcherCore/AccountProxyEnvironment.swift) 中适配自己的网络并重新构建；不要把网络读取失败直接当成账号失效。这是当前开发版本的环境限制。

## 官方功能和旧会话

模型来源、官方身份、Remote、浏览器和连接器应分别验证。保留身份不等于所有官方能力都恢复；没有对应上游接口的图片/语音能力也不会凭空获得。

切换默认不改历史。旧 provider、模型或密文无法兼容时，可能需要新建任务。不要通过批量改会话数据库、删除密文或关闭校验来掩盖来源问题。
