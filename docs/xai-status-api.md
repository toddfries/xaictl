# xAI / Grok Build status API — implementer spec

**Audience:** other tools and AI sessions that need to re-implement (or partially re-implement) what `xaictl` does, without re-deriving behaviour from the Rust monorepo.

**Reference client:** Grok Build (`xai-grok-shell` + pager), mirrored by `xaictl` (this repo). Former `xai-status.pl` / `grok-sanity` live under `deprecated/` and are not maintained.

**Last verified against live production:** 2026-08-12 (see `docs/journal.md`).

---

## 1. Overview

| Concern | Endpoint / store | Auth |
|--------|-------------------|------|
| OIDC login (interactive) | `https://auth.x.ai` authorize + token | PKCE auth-code (not needed for status scripts once `auth.json` exists) |
| OIDC refresh | `POST {token_endpoint}` | `refresh_token` grant |
| Account / credits / settings | `https://cli-chat-proxy.grok.com/v1/*` | Bearer access token from `auth.json` |
| Credential store | `~/.grok/auth.json` | file mode `0600`; lock: `auth.json.lock` |

**Important:** “How many tokens left?” in the Grok UI is **not** a raw remaining-token counter. It is **`creditUsagePercent`** of the current weekly/monthly **allowance**. Extra purchased dollars are **`prepaidBalance`** (USD cents).

---

## 2. Credential store (`auth.json`)

### 2.1 Path

- Default: `$GROK_HOME/auth.json` with `GROK_HOME` defaulting to `~/.grok`
- Overrides: `GROK_AUTH_PATH`, `XAI_STATUS_AUTH` (`xaictl --auth PATH`)

### 2.2 Shape

Top-level JSON **object**, keys = **scope strings**, values = credential objects.

Typical OIDC scope key:

```text
https://auth.x.ai::<client_id>
```

Example client id (production Grok Build OAuth2 app):

```text
b1a00492-073a-47ea-816f-4c329264a828
```

### 2.3 Credential object (fields used by status + refresh)

| Field | Type | Role |
|-------|------|------|
| `key` | string | **Access token** (JWT bearer) |
| `refresh_token` | string? | OIDC refresh token (required to renew) |
| `expires_at` | RFC3339 string? | Access-token expiry |
| `create_time` | RFC3339 string | When this credential was minted/refreshed |
| `auth_mode` | `"oidc"` \| `"api_key"` \| … | Skip `"web_login"` / legacy scopes |
| `user_id` | string | Sent as `x-userid` on proxy calls |
| `email` | string? | Optional `x-email` header |
| `oidc_issuer` | string | e.g. `https://auth.x.ai` |
| `oidc_client_id` | string | OAuth client id |
| `principal_type` | string? | e.g. `User` / `Team` |
| `principal_id` | string? | Principal UUID |
| `team_id` | string? | May be present on login even when `/user` returns null team |
| `first_name`, `last_name`, `profile_image_asset_id` | optional | Display / identity |
| `coding_data_retention_opt_out` | bool | Privacy flag |

**Never log or print `key` or `refresh_token`.**

### 2.4 Selection rules (when multiple scopes exist)

1. Skip `auth_mode` ∈ {`web_login`, `grok`} and scope `https://accounts.x.ai/sign-in`.
2. Prefer OIDC scopes with non-empty `user_id` and issuer `auth.x.ai`.
3. Fall back to `xai::api_key` only if nothing else is usable (API keys do **not** use the OIDC refresh path below).

### 2.5 Multi-process locking

- Lock file: sibling of auth path → `auth.json.lock`
- Use exclusive `flock` **across** IdP refresh + rewrite (same as Grok Build).
- On success, write `auth.json` atomically (temp file + `rename`), mode `0600`.

---

## 3. OIDC token acquisition

### 3.1 Interactive login (reference only)

Grok Build uses OAuth 2.1 auth-code + PKCE against:

| Item | Value |
|------|--------|
| Issuer | `https://auth.x.ai` |
| Discovery | `GET https://auth.x.ai/.well-known/openid-configuration` |
| Authorize | `https://auth.x.ai/oauth2/authorize` |
| Token | `https://auth.x.ai/oauth2/token` |
| Scopes (user) | `openid profile email offline_access grok-cli:access api:access conversations:read conversations:write workspaces:read workspaces:write` |

Scripts that already have a valid `auth.json` from `grok login` **do not** need the authorize step.

### 3.2 Discovery

```http
GET {issuer}/.well-known/openid-configuration
Accept: application/json
```

Use `token_endpoint` from the JSON body (production: `https://auth.x.ai/oauth2/token`).

Cache discovery for up to ~1 hour if desired (Grok does).

### 3.3 Refresh-token grant (required for long-lived scripts)

```http
POST {token_endpoint}
Content-Type: application/x-www-form-urlencoded
Accept: application/json

grant_type=refresh_token
&refresh_token={refresh_token}
&client_id={oidc_client_id}
&principal_type={principal_type}    # optional but send if present in auth.json
&principal_id={principal_id}        # optional but send if present
```

**Success (200)** JSON:

| Field | Meaning |
|-------|---------|
| `access_token` | New bearer → store as `key` |
| `expires_in` | Seconds until expiry (observed: `21600` = 6h) |
| `refresh_token` | **May be rotated.** If present, replace stored RT; if absent, **keep old RT** |
| `token_type` | usually `Bearer` |
| `id_token` | optional; Grok refresh path does not require re-parsing identity from it |

**Update `auth.json` entry:**

```json
{
  "key": "<access_token>",
  "expires_at": "<now+expires_in as RFC3339 Z>",
  "create_time": "<now RFC3339 Z>",
  "refresh_token": "<new or previous>",
  "...identity fields unchanged..."
}
```

**Error handling:**

| HTTP / `error` | Treat as | Action |
|----------------|----------|--------|
| `invalid_grant` | Terminal for **this** RT | Re-read disk; if sibling already refreshed, **adopt** disk credential. Else user must `grok login` again |
| `invalid_client` | Terminal | Config/client-id problem |
| 5xx / timeout / connect fail | Transient | Retry with backoff; do not burn escalation budget on pure network failures |
| 401 on proxy later | Transient refresh | Run refresh chain again |

### 3.4 When to refresh

Match Grok’s early-invalidation buffer:

- Refresh if `expires_at` is missing, **or**
- `now >= expires_at - 300s` (5 minutes)

Also refresh on proxy `401` before giving up.

### 3.5 Sibling adoption (mandatory for multi-process safety)

Under the file lock, **before** calling the IdP:

1. Re-read `auth.json`.
2. If disk `key` ≠ memory `key` **and** disk access token is not hard-expired → **use disk credential, skip IdP**.
3. If disk `refresh_token` ≠ memory RT → use disk RT for the exchange (sibling already rotated).

This prevents double-spend / `invalid_grant` storms when Grok and a script share one home directory.

### 3.6 Cross-machine notes

- **Shared allowance** is account-side (billing). Multiple machines can use the same xAI account.
- **Same refresh token string** refreshed concurrently on two machines can revoke one of them (`invalid_grant`). Prefer separate logins per machine, or a single shared `auth.json` with locking—not forked RT copies.

---

## 4. cli-chat-proxy HTTP conventions

### 4.1 Base URL

```text
https://cli-chat-proxy.grok.com/v1
```

Overrides: `GROK_CLI_CHAT_PROXY_BASE_URL`, `GROK_PRODUCTION_CLI_CHAT_PROXY_BASE_URL`.

### 4.2 Common headers (all authenticated GETs)

| Header | Value |
|--------|--------|
| `Authorization` | `Bearer {auth.key}` |
| `X-XAI-Token-Auth` | `xai-grok-cli` |
| `x-userid` | `{auth.user_id}` |
| `x-email` | `{auth.email}` (optional) |
| `x-grok-client-version` | any short string; Grok sends its semver |
| `x-grok-client-mode` | `interactive` or `headless` |
| `Accept` | `application/json` |

Optional Grok also sends `x-grok-client-identifier` / `x-grok-agent-id` on some routes; not required for the status GETs below.

### 4.3 Money encoding

Amounts are **integer USD cents**, often wrapped:

```json
{ "val": 1250 }
```

Proto3 JSON may omit zero → empty object `{}` means `0`.  
Some prepaid/top-up fields use **negative** cents (ledger sign). Display dollars as `abs(cents)/100` unless computing signed remaining.

---

## 5. Status endpoints

All paths are relative to the proxy base (`…/v1`).

### 5.1 `GET /billing?format=credits`  ★ preferred

**Grok path:** ACP `x.ai/billing` → this URL.  
**UI mapping:** pager `credit_balance_from_config`.

**Response (observed shape):**

```json
{
  "config": {
    "creditUsagePercent": 13.0,
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "start": "2026-08-11T01:42:54.415546+00:00",
      "end": "2026-08-18T01:42:54.415546+00:00"
    },
    "onDemandCap": { "val": 0 },
    "onDemandUsed": { "val": 0 },
    "prepaidBalance": { "val": 0 },
    "productUsage": [
      { "product": "GrokBuild", "usagePercent": 12.0 },
      { "product": "GrokChat",  "usagePercent": 1.0 }
    ],
    "isUnifiedBillingUser": true,
    "topUpMethod": "TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
    "billingPeriodStart": "…",
    "billingPeriodEnd": "…"
  }
}
```

| Field | Meaning |
|-------|---------|
| `creditUsagePercent` | 0–100 **used** fraction of included allowance (UI bar). Remaining ≈ `100 - value` |
| `currentPeriod.type` | `USAGE_PERIOD_TYPE_WEEKLY` / `…_MONTHLY` → label “Weekly/Monthly limit” |
| `currentPeriod.start/end` | Period bounds (RFC3339) |
| `prepaidBalance` | Purchased extra credit **remaining**, cents |
| `onDemandCap` / `onDemandUsed` | Pay-as-you-go cap/usage, cents (`cap > 0` ⇒ PAYG on) |
| `productUsage[]` | Per-product split of usage percent |
| `isUnifiedBillingUser` | Unified weekly/monthly pool |
| `topUpMethod` | How top-ups are charged |

**Derived fields useful in UIs/scripts:**

```text
usage_pct          = clamp(creditUsagePercent, 0, 100)
remaining_pct      = 100 - usage_pct
usage_pct_floor    = floor(usage_pct)          # Grok SpendingLimiter style
prepaid_usd        = abs(prepaidBalance)/100
has_prepaid        = abs(prepaidBalance) > 0
pay_as_you_go      = onDemandCap > 0
```

When `usage_pct >= 100` and `onDemandCap > 0`, Grok’s **effective** bar uses  
`onDemandUsed / onDemandCap * 100` instead of included percent.

---

### 5.2 `GET /billing`  (legacy)

Older monthly dollar budget:

```json
{
  "config": {
    "monthlyLimit": { "val": 40000 },
    "used": { "val": 40497 },
    "onDemandCap": { "val": 0 },
    "billingPeriodStart": "2026-08-01T00:00:00+00:00",
    "billingPeriodEnd": "2026-09-01T00:00:00+00:00",
    "history": [
      {
        "billingCycle": { "year": 2026, "month": 7 },
        "includedUsed": { "val": 0 },
        "onDemandUsed": { "val": 7863 },
        "totalUsed": { "val": 7863 }
      }
    ]
  }
}
```

Prefer **§5.1** for “how much left this period.” Keep legacy for history / older accounting.

---

### 5.3 `GET /auto-topup-rule`

```json
{
  "rule": {
    "minBeforeHittingSl": { "val": 1000 },
    "topupAmount": { "val": -1000 },
    "maxAmountPerMonth": { "val": -1000 }
  }
}
```

| Field | Meaning |
|-------|---------|
| `enabled` | Proto3: **omitted when false** → treat missing as `false` |
| `minBeforeHittingSl` | Trigger threshold, cents |
| `topupAmount` | Amount per top-up, cents (often **negative** on wire) |
| `maxAmountPerMonth` | Monthly ceiling, cents |

If `rule` is null/absent → no rule configured.

Grok only surfaces auto-topup UI when prepaid balance is positive.

---

### 5.4 `GET /user`

Profile / identity enrichment.

Notable fields (camelCase):

| JSON field | Meaning |
|------------|---------|
| `userId` | User UUID |
| `email`, `firstName`, `lastName` | Profile |
| `principalType`, `principalId` | Auth principal |
| `teamId`, `teamName`, `teamRole` | Team context (may be null) |
| `organizationId`, `organizationName`, `organizationRole`, `organizationType` | Org context |
| `userBlockedReason`, `teamBlockedReasons` | Block state |
| `codingDataRetentionOptOut` | Privacy |
| `hasGrokCodeAccess` | Whether Grok Code/Build access flag is set |

---

### 5.5 `GET /user?include=subscription`

Same as §5.4 plus:

| JSON field | Meaning |
|------------|---------|
| `subscriptionTier` | Live tier string, e.g. `XPremiumPlus`, `SuperGrok`, or empty/absent for free |

Used by Grok paywall polling (`x.ai/auth/check_subscription`). Qualifying ≈ non-empty and not `"Free"`.

---

### 5.6 `GET /settings`

Large remote-settings object. High-signal keys for status tools:

| Field | Meaning |
|-------|---------|
| `allow_access` | Server access gate for Grok Build |
| `subscription_tier` | Internal tier id |
| `subscription_tier_display` | Human label, e.g. `X Premium+` |
| `on_demand_enabled` | Whether on-demand controls are allowed |
| `usage_billing_redirect_url` | If set, UI may link out instead of showing local billing |
| `gate_message`, `gate_url`, `gate_label` | Paywall copy |
| `default_model`, `release_channel`, `min_client_version` | Client policy |
| `image_gen_enabled`, `video_gen_enabled`, `voice_mode_enabled`, … | Feature flags |
| `announcements[]`, `campaigns[]`, `tips[]` | UX content |

Grok merges `subscription_tier_display` / `on_demand_enabled` into billing UI after the credits fetch.

---

### 5.7 `GET /models`

OpenAI-ish list:

```json
{
  "object": "list",
  "data": [
    {
      "id": "grok-4.5",
      "model": "grok-4.5",
      "name": "Grok 4.5",
      "context_window": 500000,
      "api_backend": "responses",
      "reasoning_effort": "high",
      "reasoning_efforts": [ … ]
    }
  ]
}
```

---

### 5.8 Other related endpoints (not required for basic status)

| Method | Path | Role |
|--------|------|------|
| `GET` | `/login-config` | Unauthenticated login transport hints |
| `PUT` | `/privacy/coding-data-retention` | Privacy toggle |
| `POST` | `/v1/responses`, `/v1/messages`, … | Inference (burns allowance) |
| various | storage / feedback / workspaces | Product features |

---

## 5.9 Historical intel (`xaictl --no-refresh xai.history`)

There is **no** server API for tokens/day or tokens/hour. The `history` section
aggregates every available scrap:

| Source | Keys under | Contents |
|--------|------------|----------|
| `GET /billing` | `xai.history.server.monthly.*` | Current MTD used/limit (cents); past months `history[]` |
| `GET /billing?format=credits` | `xai.history.server.credits.*` | Current week % / prepaid / product split |
| `~/.grok/logs/unified.jsonl` | `xai.history.local.unified.*` | Every billing poll: change timeline, day/hour buckets, prepaid burn, fast-burn windows |
| `~/.grok/sessions/**` | `xai.history.local.sessions.*` | Session catalog, models, turns, context-window tokens by day |

```sh
xaictl --no-refresh xai.history > /tmp/xai-history.txt
```

**Coverage caveat:** unified.jsonl only records intervals when Grok on **this
host** polled billing. Other machines, Grok Chat web, and bare API keys do not
appear. Card charges / invoices are not in the CLI API.

---

## 6. Minimal implementer checklist

Copy-paste logic for a new client:

1. **Read** `~/.grok/auth.json` → pick OIDC credential with `key` + `refresh_token` + `oidc_issuer` + `oidc_client_id`.
2. If access token expires within **300s**, **flock** `auth.json.lock` → adopt sibling or **POST refresh** → write back.
3. **GET** `{proxy}/billing?format=credits` with the common headers.
4. Report:
   - `config.creditUsagePercent` (used %)
   - `100 - that` (remaining %)
   - `config.prepaidBalance.val` → dollars
   - `config.currentPeriod.end` (reset time)
   - `config.productUsage[]` (optional split)
5. Optionally **GET** `/user?include=subscription` for `subscriptionTier` and **GET** `/settings` for `subscription_tier_display` / `allow_access`.
6. Never print secrets; never spend the refresh token without holding the lock.

---

## 7. Reference implementation & man page

| Artifact | Path |
|----------|------|
| Working CLI | `xaictl` |
| Manual page | `xaictl.1` (`mandoc -a xaictl.1`) |
| This spec | `docs/xai-status-api.md` |
| Perusal journal | `docs/journal.md` |

### 7.1 Example CLI

```sh
# Status dump (auto-refresh if near expiry)
xaictl xai.credits xai.subscription

# Force refresh only
xaictl --refresh-only

# sysctl-style filter
xaictl xai.credits | grep prepaid
```

### 7.2 Timestamp output convention (`xaictl`)

All date fields are converted with **Date::Manip** to local TZ:

```text
YYYYMMDD HHMMSS.<ms> ±HH:MM
```

Example: `20260810 204254.415 -05:00`

Also emitted:

- `*.raw` — original RFC3339 from API/store  
- `*.unix` — epoch seconds  

Local zone is taken from `$TZ` or `/etc/localtime` → zoneinfo name (e.g. `US/Central`).

---

## 8. Source map (Grok Build Rust)

| Behaviour | Location |
|-----------|----------|
| Billing HTTP + types | `crates/codegen/xai-grok-shell/src/extensions/billing.rs` |
| Credit bar / usage summary | `crates/codegen/xai-grok-pager/src/views/credit_bar.rs` |
| Config → UI balance | `crates/codegen/xai-grok-pager/src/app/effects/helpers.rs` (`credit_balance_from_config`) |
| OIDC refresh exchange | `crates/codegen/xai-grok-shell/src/auth/oidc/protocol.rs` (`refresh_tokens`) |
| Pure refresh result | `crates/codegen/xai-grok-shell/src/auth/oidc/refresh.rs` |
| Persist + lock chain | `crates/codegen/xai-grok-shell/src/auth/manager.rs` (`refresh_chain`, `update`) |
| Sibling adoption | `crates/codegen/xai-grok-shell/src/auth/refresh/oidc_refresher.rs` |
| Proxy base default | `crates/codegen/xai-grok-env/src/lib.rs` |
| Settings fetch | `crates/codegen/xai-grok-shell/src/remote/client.rs` |
| Subscription poll | `crates/codegen/xai-grok-shell/src/agent/subscription_check.rs` |

---

## 9. Quick field glossary

| Concept | Wire / key | Notes |
|---------|------------|-------|
| Used allowance % | `creditUsagePercent` | Primary “bar” |
| Remaining allowance % | `100 - creditUsagePercent` | Not sent directly |
| Extra credit $ | `prepaidBalance` | Cents; abs for display |
| Reset time | `currentPeriod.end` | RFC3339 |
| Tier (live) | `subscriptionTier` on `/user?include=subscription` | |
| Tier (display) | `subscription_tier_display` on `/settings` | |
| Weekly vs monthly | `currentPeriod.type` contains `WEEKLY` / `MONTHLY` | |

---

*End of spec. Prefer live probes against production with a real `auth.json` when field names drift; the credits path (`format=credits`) is the one Grok’s `/usage` UI trusts.*
