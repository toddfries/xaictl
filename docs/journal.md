# grok-build source perusal journal

docs/* (and the status trees they describe) were originally derived by
perusing Grok Build sources under `/home/todd/git/sw/grok-build`. If
`xaictl` output starts lying, or about weekly, re-walk the source map in
`docs/xai-status-api.md` §8 and append a row here.

Canonical id is `SOURCE_REV` (upstream monorepo). Also record local git
HEAD when it differs. Next due: 2026-08-19.

Format: `YYYY-MM-DD  <SOURCE_REV>  brief changes found list`

---

2026-08-12  5d08d7e4123092567ccd584cd9f99afa2972065c  first perusal baseline (local git HEAD 89301bed “Synced from monorepo”); mapped billing/auth/settings/models paths still present; live credits URL still GET /billing?format=credits; headers still Authorization + X-XAI-Token-Auth + x-userid + x-grok-client-version + client-mode; auto-topup still GET /auto-topup-rule; unified-log line still “billing: fetched credits config”; productUsage still unused by CLI Rust BillingConfig (raw JSON still has it); live productUsage now includes GrokPlugins in addition to GrokBuild/GrokChat; unified-log history compacted to historyLen+latestHistory; handle_get_billing comment still mentions GET /rest/grok/credits while the live URL is /billing?format=credits
