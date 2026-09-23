> EXAMPLES

# xai.credits

```
$ ./xaictl xai.credits
xai.credits.http.url=https://cli-chat-proxy.grok.com/v1/billing?format=credits
xai.credits.http.status=200
xai.credits.http.ok=true
xai.credits.credit_usage_percent=100
xai.credits.credit_usage_percent_floor=100
xai.credits.credit_remaining_percent=0
xai.credits.credit_remaining_percent_floor=0
xai.credits.period.type=USAGE_PERIOD_TYPE_WEEKLY
xai.credits.period.start.raw=2026-09-22T01:42:54.415546+00:00
xai.credits.period.start=20260921 204254.415 -05:00
xai.credits.period.start.unix=1790041374
xai.credits.period.end.raw=2026-09-29T01:42:54.415546+00:00
xai.credits.period.end=20260928 204254.415 -05:00
xai.credits.period.end.unix=1790646174
xai.credits.period.label=Weekly limit
xai.credits.period.seconds_until_reset=457350
xai.credits.prepaid_balance_cents=0
xai.credits.prepaid_balance_usd=0.00
xai.credits.has_prepaid_credits=false
xai.credits.on_demand_cap_cents=0
xai.credits.on_demand_cap_usd=0.00
xai.credits.on_demand_used_cents=0
xai.credits.on_demand_used_usd=0.00
xai.credits.pay_as_you_go=false
xai.credits.effective_usage_percent=100
xai.credits.effective_usage_percent_floor=100
xai.credits.is_unified_billing_user=true
xai.credits.top_up_method=TOP_UP_METHOD_SAVED_PAYMENT_METHOD
xai.credits.billing_period_start.raw=2026-09-22T01:42:54.415546+00:00
xai.credits.billing_period_start=20260921 204254.415 -05:00
xai.credits.billing_period_start.unix=1790041374
xai.credits.billing_period_end.raw=2026-09-29T01:42:54.415546+00:00
xai.credits.billing_period_end=20260928 204254.415 -05:00
xai.credits.billing_period_end.unix=1790646174
xai.credits.product_usage.count=3
xai.credits.product_usage.GrokBuild.product=GrokBuild
xai.credits.product_usage.GrokBuild.usage_percent=92
xai.credits.product_usage.GrokBuild.usage_percent_floor=92
xai.credits.product_usage.GrokBuild.remaining_percent=8
xai.credits.product_usage.0.product=GrokBuild
xai.credits.product_usage.0.usage_percent=92
xai.credits.product_usage.GrokAppBuilder.product=GrokAppBuilder
xai.credits.product_usage.GrokAppBuilder.usage_percent=7
xai.credits.product_usage.GrokAppBuilder.usage_percent_floor=7
xai.credits.product_usage.GrokAppBuilder.remaining_percent=93
xai.credits.product_usage.1.product=GrokAppBuilder
xai.credits.product_usage.1.usage_percent=7
xai.credits.product_usage.GrokTasks.product=GrokTasks
xai.credits.product_usage.GrokTasks.usage_percent=1
xai.credits.product_usage.GrokTasks.usage_percent_floor=1
xai.credits.product_usage.GrokTasks.remaining_percent=99
xai.credits.product_usage.2.product=GrokTasks
xai.credits.product_usage.2.usage_percent=1
xai.credits.summary.usage_line=Weekly limit: 100%
```
# signals from a session
```
t0|todd@mydesktop/qS ~/git/sw/xaictl|806$ ./xaictl -S 019ff6dd-4a75-7df2-9a7d-c1d65819d458 xai.signals
xai.signals.session_id=019ff6dd-4a75-7df2-9a7d-c1d65819d458
xai.signals.signals_file=/home/todd/.grok/sessions/%2Fhome%2Ftodd%2Fgit%2Fsw%2Fgrokapi/019ff6dd-4a75-7df2-9a7d-c1d65819d458/signals.json
xai.signals.compaction_count=0
xai.signals.context_tokens_used=210376
xai.signals.context_window_tokens=500000
xai.signals.context_window_usage=42
xai.signals.error_count=1
xai.signals.primary_model_id=grok-4.6
xai.signals.session_duration_secs=2332
xai.signals.tool_call_count=144
xai.signals.turn_count=3
xai.signals.note=context_window_usage is harness context-fill % (not SuperGrok consumer quota)
t0|todd@mydesktop/qS ~/git/sw/xaictl|807$
