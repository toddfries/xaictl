```
Subject: xaictl - x.AI sysctl like output for API metrics
From: Todd T. Fries <todd@fries.net>
To: anyone reading this
```
# xaictl

> x.AI sysctl-like output for API metrics


I got tired of browsing to get my API info so I commissioned this from grok-build.

It even looked into its own code for some of this.

Because of that, you can set a normal key and a management key in, by default:

```ini
# ~/.config/cxai/grok.conf
[mgmt]
bearer = xai-token-...

[creds]
xai-...
```

You can also check on grok build token pool that gets its auth from:

```bash
$HOME/.grok/auth.json  # obeys GROK_BUILD_HOME, see the man page
```

Don't get excited if you want token counts; I believe that's not available.

## What it provides

- **%** – Free pool usage (with timing)
- **$** – Credits left (`$0.00` means you've used them all or haven't purchased any)

See [EXAMPLES.md](EXAMPLES.md) for examples.

---

```
--
Todd Fries .. todd@fries.net .. 𝕏:@unix2mars .. github:toddfries

Label   | Data           | Notes
--------+----------------+------------------------------
Motto   | In support of  | free software solutions.
Phone   | 1.405.252.0702 | SMS/voice everywhere
Mobile  | 1.405.203.6124 | SMS/voice mobile only
Employer| self employed  | Free Daemon Consulting, LLC
Address | PO Box 16169   | Oklahoma City, OK 73113-2169
PGP     | 3F42004A       |
```
