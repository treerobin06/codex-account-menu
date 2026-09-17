# 开发与测试

## 目录

- `apps/codex-account-menu/Sources`：SwiftUI/AppKit 界面、切换核心、CLI 与内置 relay/额度采集器。
- `apps/codex-account-menu/Tests`：合成账号、配置事务和本机传输测试。
- `init/copilot-proxy`：固定上游指针、适配补丁与可选服务模板。
- `init/copilot-proxy/mac-transport`：可选的私有入口与恢复示例；与账号 App 的正常使用分开。

## 本地回归

```sh
bash apps/codex-account-menu/scripts/test.sh
python3 -m unittest discover -s init/copilot-proxy -p 'test_*.py'
python3 -m unittest discover -s init/copilot-proxy/mac-transport -p 'test_*.py'
node --test init/copilot-proxy/mac-transport/test_live_http_policy.mjs
```

根目录 `scripts/test-all.sh` 汇总这些检查。传输集成测试还需要 HAProxy，请按其 README 提供二进制路径。测试使用隔离目录与 loopback 服务，不调用生产来源切换或真实模型。缺少外部条件的检查必须明确报告，不能把构建成功当作测试通过。

真实模型脚本只在显式 live 参数下运行，并可能消耗账号额度；不作为普通发布步骤。运行前审查目标来源、临时目录、成本和当前桌面任务。

## 构建与签名

```sh
cd apps/codex-account-menu
bash scripts/build-app.sh release
```

默认输出在当前用户的 `~/Library/Caches/Codex Account Menu/build/release/`。`--output DIR` 可改输出位置；`--skip-build` 仅打包已有二进制，不应拿它证明包含最新源码。

公开二进制应从不含个人用户名的干净构建目录产生，并在打包前扫描二进制、资源与 ZIP 文件名。App 和 CLI 分别验签；压缩后重新解压验签，并附第三方许可文本。

## 演示与现场验收

`build-app.sh debug --demo-bundle` 创建独立标识、永久演示标记的测试包。演示数据必须明确标识，不能导入正式账号或作为真实额度截图。正式安装器拒绝演示包。

自动化测试不替代真实菜单点击、目标客户端正常退出/重开、有效身份、模型路由或手机功能验收。默认不动历史、不强杀无关进程、不自动升级活动 helper。
