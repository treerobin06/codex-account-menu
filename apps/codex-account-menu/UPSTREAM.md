# Upstream

Selected SwitcherCore and tests are based on liuzhao1225/codex-account-switcher v0.1.12 (MIT).

Source: https://github.com/liuzhao1225/codex-account-switcher/tree/v0.1.12

Downloaded archive SHA-256: 7d4b822ae47d46140d537f934ae681c5b7639e232e98d85a48bd42ccf4c90082

The UI, provider transaction, and remote Copilot collector are local adaptations. No Sparkle or other third-party package is required.

History/provider design references: CC Switch v3.20.3 (MIT), especially `codex_history_migration.rs`; CodexPlusPlus v1.3.0 (AGPL-3.0), especially `provider_sync.rs` and its built-in OpenAI endpoint routing. Session synchronization and the Node relay here are original implementations, not copied or linked AGPL code. No upstream application, renderer injection, phone relay or database package is installed.

OpenAI configuration reference (accessed September 16, 2026): https://learn.chatgpt.com/docs/config-file/config-reference — documents `openai_base_url` as the built-in OpenAI model provider base URL override. This does not establish that mobile Remote billing has been tested.
