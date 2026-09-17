# 第三方来源

本仓库已公开，未替新增代码另行选择公共开源许可证。已有第三方文件和派生部分继续遵守各自许可证。

- 账号切换核心与部分测试参考/派生自 `liuzhao1225/codex-account-switcher` v0.1.12，MIT。原始版权与许可证保存在 [LICENSE.upstream](apps/codex-account-menu/LICENSE.upstream)，版本说明见 [UPSTREAM.md](apps/codex-account-menu/UPSTREAM.md)。
- Copilot 适配基于 `Jer-y/copilot-proxy` v0.10.0，固定提交记录在 [UPSTREAM](init/copilot-proxy/UPSTREAM)，完整 MIT 文本保存在 [LICENSE.upstream](init/copilot-proxy/LICENSE.upstream)。本仓库只包含相应补丁及外围维护文件，不捆绑完整上游依赖树。
- CC Switch 和 CodexPlusPlus 仅作为已记录的设计与行为对照，不捆绑这两款应用。现有来源说明记录会话同步和 Node relay 为本地实现；未因打包而新增 AGPL 代码或链接依赖。
- Node/Bun、HAProxy、Codex 与 ChatGPT 客户端需另行提供，本次附件不包含这些程序。

编译 App 附件会一并带上本声明与上述许可证。具体第三方权利以各文件保留的许可文本为准。
