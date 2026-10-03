---
page_title: "soroush_check Data Source - Soroush"
subcategory: ""
description: |-
  Reads an existing Soroush Check, so that a rule in one workspace can select Checks managed in another.
  Look one up either by id, or by project_id together with logical_name — a logical_name is unique within its Project, not across the Account, so the pair is the key. Every other attribute is read from the platform.
  The Check's runtime state — whether it is currently up, its failing streak, its latest result — is deliberately absent: this data source reports configuration only, so referencing it cannot make a plan change every time a Check flaps.
---

# soroush_check (Data Source)

Reads an existing Soroush Check, so that a rule in one workspace can select Checks managed in another.

Look one up either by `id`, or by `project_id` together with `logical_name` — a `logical_name` is unique within its Project, not across the Account, so the pair is the key. Every other attribute is read from the platform.

The Check's runtime state — whether it is currently up, its failing streak, its latest result — is deliberately absent: this data source reports configuration only, so referencing it cannot make a plan change every time a Check flaps.

## Example Usage

```terraform
# A complete, runnable root module reading Checks it does not manage.
#
# This is the cross-workspace case: the Checks live in another state file (or were
# made in the dashboard, or by the deployment manifest), and this workspace only
# needs to point an Alert Rule at them. Reading a Check does not claim it —
# `origin` is reported as the platform holds it, and no plan proposes to change
# it.

terraform {
  required_version = ">= 1.5"

  required_providers {
    soroush = {
      source  = "DanaAIhq/soroush"
      version = "~> 0.1"
    }
  }
}

provider "soroush" {}

# Route one: by platform id.
#
# Do not also set `project_id` here. The id is a whole key on its own, and a
# `project_id` alongside it would be a second, unused key rather than a
# narrowing — so the provider rejects the pair instead of quietly ignoring it.
data "soroush_check" "by_id" {
  id = "chk_01HQ8Z0X6ABCDEFGHJKMNPQRS"
}

# Route two: by Project and name.
#
# Both halves are required together, because a `logical_name` is unique within a
# Project and not across the Account: two Projects may each hold a Check called
# `checkout-api`.
data "soroush_check" "by_name" {
  project_id   = "shop"
  logical_name = "checkout-api"
}

# What a data source is for: selecting Checks this workspace does not own.
resource "soroush_alert_rule" "checkout_down" {
  project_id = "shop"

  check_selector = {
    check_ids = [
      data.soroush_check.by_id.id,
      data.soroush_check.by_name.id,
    ]
  }

  fire_on  = "down"
  severity = "critical"

  max_notification_rate = {
    max_notifications = 3
    window_seconds    = 3600
  }

  channels = ["ch_oncall_email"]
}

output "checkout_api_interval_seconds" {
  description = "Configuration is readable; runtime state is not returned at all."
  value       = data.soroush_check.by_name.interval_seconds
}

output "checkout_api_origin" {
  description = "Which write path manages the Check on the platform, reported as-is."
  value       = data.soroush_check.by_name.origin
}
```

## The two lookup routes

Set `id`, **or** set `project_id` and `logical_name` together. Both halves of the
by-name key are required because a `logical_name` is unique within its Project and
not across the Account — two Projects may each hold a `checkout-api`.

`project_id` alongside `id` is rejected rather than ignored. An id is already a
whole key, so a second one is not a narrowing; it is a mistake worth surfacing.

The by-name route lists the Account's Checks and filters locally, because the API
has no filter parameter for it. A lookup matching nothing fails with a diagnostic
naming the key you gave.

## Reading does not claim

`origin` is reported exactly as the platform holds it — `terraform`, `api`, or
`manifest` — and unlike the `soroush_check` resource, nothing here plans to change
it. A data source reads; it takes no ownership, so pointing one at a
manifest-managed Check leaves that Check under manifest reconciliation.

## What Terraform state contains for this data source

A data source result is recorded in state like any other, so state holds a
clear-text copy of everything read back: URLs, header names **and their values**,
request bodies, browser scripts, secret **references**, locations, thresholds,
`origin`, `account_id`, and `id`. It holds no secret **value** — the platform
stores none on a Check — and no runtime state or run results, which the provider
drops so that a flapping Check never becomes a plan change.

The same two consequences as the resource: use a remote backend with encryption at
rest and restricted read access, and keep the `api_key` in `SOROUSH_API_KEY`
rather than in a `provider` block, where a saved plan file would record it.

## Masked values

Values the API masks on read come back as the literal `***REDACTED***` here.
Unlike the resource, a data source has no prior state to keep in their place, so
that is what you get. Do not build a configuration that depends on a masked value
being the real one.

<!-- schema generated by tfplugindocs -->
## Schema

### Optional

- `id` (String) The Check's platform id (`checkId`). One of the two lookup keys: set this, or set `project_id` and `logical_name`.
- `logical_name` (String) The Check's name within its Project. The other half of the by-name lookup key, and not a key on its own: two Projects may each hold a Check called `checkout-api`.
- `project_id` (String) The Project the Check belongs to. Half of the by-name lookup key: give it together with `logical_name`.

### Read-Only

- `account_id` (String) The Account that owns the Check. Determined by the API key: a key is bound to exactly one Account, so a lookup can only ever find a Check in that one.
- `api` (Attributes) The API spec: an ordered sequence of requests per run. (see [below for nested schema](#nestedatt--api))
- `browser` (Attributes) The browser spec: a script run in a real browser. (see [below for nested schema](#nestedatt--browser))
- `enabled` (Boolean) Whether the Check is scheduled.
- `failure_threshold` (Number) Consecutive failing runs before the Check is considered down.
- `interval_seconds` (Number) How often the Check runs, in seconds.
- `latency_sensitive` (Boolean) Whether the Check is marked latency-sensitive.
- `locations` (Set of String) The locations the Check runs from.
- `max_retries` (Number) Retries within a single run before it counts as a failure.
- `origin` (String) Which write path manages the Check: `terraform`, `api`, or `manifest`. Reported as the platform holds it — reading a Check does not claim it, so unlike the `soroush_check` resource this never plans an ownership change.
- `resource_profile` (Attributes) Right-sizing for the Check's runner. (see [below for nested schema](#nestedatt--resource_profile))
- `secrets_refs` (Set of String) Secret references the Check may resolve at run time.
- `type` (String) `uptime`, `api`, or `browser`. Exactly one spec attribute is set.
- `uptime` (Attributes) The uptime spec: one request or connection per run. (see [below for nested schema](#nestedatt--uptime))
- `warm_pool` (Attributes) Warm capacity kept ready for a latency-sensitive Check. (see [below for nested schema](#nestedatt--warm_pool))

<a id="nestedatt--api"></a>
### Nested Schema for `api`

Read-Only:

- `response_time_threshold_ms` (Number) Total response time above which a run counts as degraded.
- `step` (Attributes List) The requests, in order. (see [below for nested schema](#nestedatt--api--step))

<a id="nestedatt--api--step"></a>
### Nested Schema for `api.step`

Read-Only:

- `assertion` (Attributes List) Assertions over the step's response. (see [below for nested schema](#nestedatt--api--step--assertion))
- `body` (String) The request body.
- `expected_status` (Number) The status this step must answer with.
- `extract` (Attributes List) Values pulled out of the response for a later step. (see [below for nested schema](#nestedatt--api--step--extract))
- `headers` (Map of String) Request headers. A header the platform considers sensitive reads back as `***REDACTED***`: the platform masks it, and a data source has no earlier value to substitute, so the mask is what lands in state. It is stable across reads, so it introduces no per-plan change — but it is not the value either.
- `method` (String) The HTTP method.
- `url` (String) The request URL.

<a id="nestedatt--api--step--assertion"></a>
### Nested Schema for `api.step.assertion`

Read-Only:

- `comparator` (String) How the source is compared to `expected`.
- `expected` (String) The expected value.
- `path` (String) The path into the source.
- `source` (String) What the assertion reads.


<a id="nestedatt--api--step--extract"></a>
### Nested Schema for `api.step.extract`

Read-Only:

- `name` (String) The placeholder name a later step substitutes.
- `path` (String) The path into the source.
- `source` (String) Where the value is read from.




<a id="nestedatt--browser"></a>
### Nested Schema for `browser`

Read-Only:

- `max_execution_ms` (Number) Wall-clock budget for the script, in milliseconds.
- `otel_enabled` (Boolean) Whether the run emits OpenTelemetry traces.
- `script` (String) The script the Check runs.


<a id="nestedatt--resource_profile"></a>
### Nested Schema for `resource_profile`

Read-Only:

- `compute` (String) The compute backend the platform runs the Check on.
- `memory_mb` (Number) Memory for the runner, in MB.
- `timeout_ms` (Number) Run timeout, in milliseconds.


<a id="nestedatt--uptime"></a>
### Nested Schema for `uptime`

Read-Only:

- `connect_timeout_ms` (Number) Connection timeout, in milliseconds.
- `expected_status_range` (Attributes) The response status range that counts as up. (see [below for nested schema](#nestedatt--uptime--expected_status_range))
- `heartbeat_interval_seconds` (Number) How often a `heartbeat` Check expects to be reported in to.
- `mode` (String) `url`, `tcp`, or `heartbeat`.
- `port` (Number) Port for a `tcp` Check.
- `target` (String) What the Check checks.

<a id="nestedatt--uptime--expected_status_range"></a>
### Nested Schema for `uptime.expected_status_range`

Read-Only:

- `max` (Number) Highest status that counts as up, inclusive.
- `min` (Number) Lowest status that counts as up, inclusive.



<a id="nestedatt--warm_pool"></a>
### Nested Schema for `warm_pool`

Read-Only:

- `min` (Number) Minimum number of warm runners.
