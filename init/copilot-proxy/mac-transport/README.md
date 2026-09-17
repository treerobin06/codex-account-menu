# 可选的 Mac 私有传输

本目录是已有 Copilot 代理的高级传输示例，不是账号 App 的必装部分。它不附带服务器地址、私钥或已配置的网络，也不会自动登录 VPN。

## 结构

本机 `4142` 是账号 App 的 relay；`4141` 可以由 HAProxy 汇总你自行配置的私有 SSH 路径。主备入口面向同一个上游身份，不会自动切换计费账号。

| 路径名称 | 本机端口 | 用途 |
|---|---:|---|
| `primary` | 14141 | 主要私有入口 |
| `backup` | 14142 | 备用入口 |
| `direct` | 14143 | 可选、绑定物理接口的直接路径 |
| `jump` | 14144 | 可选、经过独立 SSH 身份的跳板路径 |

已有长连接不能无损搬到另一条断开的线路；不会自动重放模型 POST 来掩盖失败。

## 目录和配置

状态位于 `~/.local/state/copilot-transport`，工具位于 `~/.local/share/copilot-transport`。实际 SSH 目标需要明确提供，缺失时拒绝连接：

| 环境变量 | 含义 |
|---|---|
| `COPILOT_PRIMARY_HOST` / `COPILOT_BACKUP_HOST` | 主、备 IPv4 端点；必填 |
| 对应的 `_PORT` | SSH 端口，默认 22 |
| `COPILOT_SSH_USER` | 自己的远端用户；默认当前用户名 |
| `COPILOT_SSH_IDENTITY_FILE` | 自己的 SSH 私钥路径，默认 `~/.ssh/id_ed25519` |
| `COPILOT_DIRECT_HOST` / `COPILOT_JUMP_HOST` | 追加路径使用的端点；需要这些路径时必填 |
| `COPILOT_HAPROXY_BINARY` | 已有 HAProxy 二进制路径；可用于测试 |
| `COPILOT_BUILD_CACHE` | HAProxy 构建缓存目录 |

服务器主机别名为 `copilot-server`，跳板别名为 `copilot-jump`。部署者应通过可信方式预先核验主机密钥；代码保持严格主机校验、禁止 agent forwarding，并给跳板使用独立身份。

`.plist.in` 是模板，`{{HOME}}` 需要按目标用户渲染，不能直接加载未替换模板。`stage` 针对已存在的单隧道入口做隔离准备，不是从零安装向导；执行前应阅读代码并确认已有服务布局。

## 检查与测试

```sh
python3 copilot-link.py status
python3 copilot-link.py doctor
```

这两个命令读取已部署状态。`doctor` 分别查看 relay、应用就绪和模型目录，并区分完整程序版本与已应用的网络预算。

本地合成测试：

```sh
export COPILOT_HAPROXY_BINARY="/path/to/your/haproxy"
python3 -m unittest discover -s . -p 'test_*.py'
node --test test_live_http_policy.mjs
```

测试使用 loopback 假服务。缺少所需二进制或支持条件时应明确报告，不能把未执行视为通过。测试中的文档地址不是可用节点。

## 修改与恢复边界

`cutover`、`rollback` 和动态路径变更会影响传输，必须在目标环境核验活动连接、锁、原始配置与回退路径后执行。它们不应作为 README 快速启动中的自动步骤。

`live_http_update.py` 是处理特定旧 helper 的一次性兼容工具：需要当前来源/账号库绑定和共享锁通过，使用短时本机管理通道，只调整限定上游的新 HTTP 请求预算。它不属于普通启动或刷新；正常部署新 helper 无需使用它。

本目录移除了个人部署历史。公开验证只承诺隔离测试的范围，不代表任意网络、系统睡眠或目标主机均已通过现场验收。
