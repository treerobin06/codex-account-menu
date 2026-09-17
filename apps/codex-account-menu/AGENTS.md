# Contributor guidance

- Keep this app focused on account identity, inference source, quota and bounded local activity. Do not manage unrelated skills, MCP servers, plugins or global proxy settings.
- Never commit credentials, account stores, real conversations, runtime snapshots or personal network settings. Use clearly synthetic fixtures.
- Keep account-only RPCs and effective-configuration authentication checks separate. Quota must be associated with the verified account ID returned with it.
- All credential readers and switches share the existing lock. Wait for owned helpers to exit before releasing it; never terminate unrelated writers.
- Preserve unknown configuration bytes. Keep updates idempotent, atomic and recoverable; an interrupted switch must preserve its pending marker across UI restarts.
- The account store belongs to one canonical Codex home. Never bypass its binding or reuse another home's registry.
- Default source switches must not modify session indexes or rollout history. Isolated history diagnostics must remain restricted to temporary homes.
- Only normal desktop termination is permitted after the user explicitly confirms a switch. Do not disconnect an active maintenance conversation to test the switcher.
- Keep relay traffic on loopback and the configured upstream. Strip official identity credentials, refuse redirects/fallback and require idle connections for shutdown or upgrade.
- Conversation previews are bounded read-only views of public user/assistant messages. Never include system, developer, hidden reasoning or tool bodies.
- Match transport attribution by exact thread ID. A connection is not a turn; an HTTP status is not generation completion or billing proof.
- Use the independently identified demo bundle for UI fixtures. Production must show real imported accounts and real fetched values.
- Build signed artifacts outside provider-managed folders. Do not remove quarantine or weaken trust settings.
- Run scripts/test.sh and check that Swift Testing actually executed tests. Keep live model checks explicitly opt-in and report skipped checks.
- Keep browser, Remote, effective identity, routing and actual GUI switching acceptance separate. Do not promote a configuration check to end-to-end success.
