---
page_title: "soroush_check Resource - Soroush"
subcategory: ""
description: |-
  A Soroush Check: an uptime, API, or browser monitor that runs on a schedule from one or more locations.
  Exactly one of uptime, api, and browser must be set; type is computed from which one it is.
---

# soroush_check (Resource)

A Soroush Check: an uptime, API, or browser monitor that runs on a schedule from one or more locations.

Exactly one of `uptime`, `api`, and `browser` must be set; `type` is computed from which one it is.

## Example Usage

```terraform
# A complete, runnable root module declaring one Check of each type.
#
# Exactly one of `uptime`, `api`, and `browser` is set on each — that is what
# gives a Check its `type`, which the provider computes rather than asking you to
# state twice.

terraform {
  required_version = ">= 1.5"

  required_providers {
    soroush = {
      source  = "DanaAIhq/soroush"
      version = "~> 0.1"
    }
  }
}

# Credential and endpoint come from SOROUSH_API_KEY and SOROUSH_API_URL.
provider "soroush" {}

# ---------------------------------------------------------------------------
# An uptime Check: one HTTP request per run.
# ---------------------------------------------------------------------------
resource "soroush_check" "storefront" {
  project_id       = "shop"
  logical_name     = "storefront"
  interval_seconds = 60
  locations        = ["eu-central-1", "us-east-1"]

  uptime = {
    mode   = "url"
    target = "https://shop.example.com/"

    # Required whenever `mode = "url"`. The provider checks that at plan time,
    # because it needs no knowledge of your Account to know it is missing.
    expected_status_range = {
      min = 200
      max = 299
    }
  }
}

# ---------------------------------------------------------------------------
# An API Check: an ordered sequence of requests, where a later step substitutes
# a value an earlier one extracted.
# ---------------------------------------------------------------------------
resource "soroush_check" "checkout_api" {
  project_id       = "shop"
  logical_name     = "checkout-api"
  interval_seconds = 60
  locations        = ["eu-central-1"]

  # Secret references, never secret values. The value behind a reference is set
  # out of band with `soroush secret set`; this provider defines no attribute
  # whose purpose is a secret value.
  secrets_refs = ["shop/checkout-token"]

  api = {
    response_time_threshold_ms = 1500

    step = [
      {
        method          = "POST"
        url             = "https://shop.example.com/api/session"
        expected_status = 201
        body            = jsonencode({ user = "synthetic-probe" })

        headers = {
          "Content-Type" = "application/json"

          # $${…} — the doubled dollar escapes Terraform's own interpolation, so
          # the platform receives the literal ${secret:shop/checkout-token} and
          # resolves it at run time. Written with a single `$` this is an HCL
          # error about an unknown object named `secret`.
          "X-Api-Key" = "$${secret:shop/checkout-token}"
        }

        assertion = [
          {
            source     = "jsonPath"
            comparator = "exists"
            path       = "$.token"
          },
        ]

        # Names a value for a later step to substitute as $${session_token}.
        extract = [
          {
            name   = "session_token"
            source = "jsonPath"
            path   = "$.token"
          },
        ]
      },
      {
        method          = "GET"
        url             = "https://shop.example.com/api/checkout/health"
        expected_status = 200

        headers = {
          "Authorization" = "Bearer $${session_token}"
        }

        assertion = [
          {
            source     = "jsonPath"
            comparator = "equals"
            path       = "$.status"
            expected   = "ok"
          },
        ]
      },
    ]
  }
}

# ---------------------------------------------------------------------------
# A browser Check, with every optional attribute the resource has, so the shape
# of each is visible in one place.
#
# The platform accepts, validates, stores, and schedules a browser Check, but its
# browser runner is not provisioned yet, so the Check does not execute. The
# provider says so as a plan-time warning rather than letting you discover it
# from a monitor that never reports.
# ---------------------------------------------------------------------------
resource "soroush_check" "checkout_journey" {
  project_id       = "shop"
  logical_name     = "checkout-journey"
  interval_seconds = 900
  locations        = ["eu-central-1"]

  # Every one of these has a platform default; they are stated here to show the
  # attribute, not because the default is wrong.
  enabled           = true
  failure_threshold = 2
  max_retries       = 1
  latency_sensitive = true

  # Warm capacity, which only means anything for a latency-sensitive Check.
  # Removing the attribute clears it on the platform.
  warm_pool = {
    min = 1
  }

  # Right-size the runner. Omit the attribute entirely to take the platform's
  # per-type default, which the provider then keeps in state rather than
  # replanning it on every run.
  resource_profile = {
    compute    = "fargate"
    memory_mb  = 2048
    timeout_ms = 120000
  }

  browser = {
    script           = <<-EOT
      await page.goto('https://shop.example.com');
      await page.click('text=Checkout');
      await page.waitForSelector('#order-summary');
    EOT
    max_execution_ms = 120000
    otel_enabled     = true
  }
}

output "storefront_check_id" {
  description = "The platform id the Check was assigned, which is also its import id."
  value       = soroush_check.storefront.id
}
```

## What Terraform state contains for this resource

State holds a clear-text copy of every attribute below. For a Check that means:
the Project and logical name, the interval, the locations, the thresholds and
retry count, the warm pool and resource profile, and the **whole spec** — request
URLs, header names *and their values*, request bodies, browser scripts, assertion
paths and expected values — together with the secret **references** in
`secrets_refs`, the computed `origin`, `account_id`, and `id`.

State never holds a secret **value**: no attribute on this resource carries one,
by design. It also never holds the Check's runtime state or its run results — the
provider drops both, so a flapping Check never shows up as a plan change.

Two things follow. Use a remote backend with encryption at rest and restricted
read access, because an internal hostname or a header value is in the state file
the moment it is in a Check. And keep the `api_key` in `SOROUSH_API_KEY` rather
than in a `provider` block: state never records provider configuration either
way, but a saved plan file records a literal `api_key` from HCL.

## Placeholders, and the `$${…}` escape

The platform resolves `${secret:<ref>}` to a secret value and `${<name>}` to a
value an earlier `api.step` extracted, at run time, on the runner. Both collide
with HCL's own interpolation, so in Terraform they take a doubled dollar —
`$${secret:shop/token}`, `$${session_token}` — and the provider receives the
single-dollar form the platform expects.

Every one of these attributes can carry a placeholder, and each repeats the note
in its own description below:

- `secrets_refs`
- `uptime.target`
- `api.step[*].url`
- `api.step[*].headers` — the values
- `api.step[*].body`
- `api.step[*].assertion[*].expected`
- `browser.script`

A forgotten escape is an HCL error about an unknown object named `secret`, not a
silently stored literal. That is deliberate: the failure is loud and local.

## Masked values are not drift-detectable

Where the API masks a value on read — answering `***REDACTED***` rather than what
it stored — the provider keeps whatever is already in state for that attribute.
Writing the mask into state would make every plan afterwards propose replacing a
real value with the literal string `***REDACTED***`, forever.

The cost: **a masked value that changes on the platform is invisible to
`terraform plan`.** There is nothing to compare it against, so drift in it is
neither reported nor corrected. Give credentials as secret references instead;
then it is the reference that lives in state and gets compared, and the value the
platform resolves is never Terraform's business at all.

## Ownership: re-claim, and what a dashboard edit does

`origin` is computed, and it is the one computed attribute that is *meant* to
disagree with state. Every write this provider makes declares `terraform`. If
someone edits the Check in the dashboard, the platform records `origin = "api"`;
the next `terraform plan` shows `origin` changing back to `"terraform"` — a
**re-claim** — beside whatever else that edit changed, and applying restores the
configuration and takes management back.

A re-claim with no other change sends an empty patch: the platform re-records the
provenance and touches nothing else, so no schedule is disturbed and no run is
lost.

## Import

```shell
#!/usr/bin/env bash
# Import an existing Check by its platform id. The dashboard's Terraform section
# prints this exact command for any Check you are looking at.
terraform import soroush_check.storefront chk_01HQ8Z0X6ABCDEFGHJKMNPQRS

# Import writes the id and nothing else, so the Check keeps whatever `origin` the
# platform holds — `api` for one made in the dashboard, `manifest` for one
# deployed from a manifest. The *next* plan proposes changing it to `terraform`,
# and the apply after that is what transfers management. Adoption is therefore
# something you see and approve, not a side effect of typing `terraform import`.
terraform plan

# For a manifest-origin Check, read that plan carefully: applying it removes the
# Check from deployment-manifest reconciliation for good, and the code-first
# team's next `soroush deploy` reports it as a conflict rather than a change.
# There is no way back other than deleting it here and re-declaring it there.
```

Import writes the `id` and nothing else. The Check therefore keeps whatever
`origin` the platform holds, and the *next* plan proposes the re-claim — so
adopting a monitor is a change you read and approve, not a side effect of typing
`terraform import`.

~> **Importing a manifest-origin Check is one-way.** A Check deployed from a
Soroush deployment manifest carries `origin = "manifest"`. Once you import it and
apply, its origin is `terraform` and manifest reconciliation **stops covering it
for good**: the code-first team's next `soroush deploy` reports it as a conflict
rather than a change, and will neither update nor delete it. There is no
un-import. If that is not what you want, delete the Check from the manifest and
re-declare it here deliberately, or leave it where it is.

<!-- schema generated by tfplugindocs -->
## Schema

### Required

- `interval_seconds` (Number) How often the Check runs, in seconds.
- `locations` (Set of String) The locations the Check runs from. A set: the platform schedules each location independently, so the order carries nothing. Which locations exist is an Account-scoped fact the API owns — an unprovisioned one is rejected with a message naming the provisioned set.
- `logical_name` (String) The Check's name within its Project, unique per Project. Updatable in place — renaming a Check keeps its id, its history, and its Check state.
- `project_id` (String) The Project the Check belongs to. Changing it replaces the Check: the API rejects `projectId` in a `PATCH` as immutable, so there is no in-place move.

### Optional

- `api` (Attributes) An API Check: an ordered sequence of requests per run, where a step can use a value an earlier step extracted. Sets `type` to `api`. (see [below for nested schema](#nestedatt--api))
- `browser` (Attributes) A browser Check: a script run in a real browser. Sets `type` to `browser`. The platform accepts, validates, stores, and schedules one, but its browser runner is not yet provisioned, so the Check does not execute yet — the provider says so at plan time. (see [below for nested schema](#nestedatt--browser))
- `enabled` (Boolean) Whether the Check is scheduled. Defaults to `true`.
- `failure_threshold` (Number) Consecutive failing runs before the Check is considered down. Defaults to `1`.
- `latency_sensitive` (Boolean) Marks the Check as latency-sensitive, which is what makes `warm_pool` meaningful. Defaults to `false`.
- `max_retries` (Number) Retries within a single run before it counts as a failure. Defaults to `2`.
- `resource_profile` (Attributes) Right-sizing for the Check's runner. The platform defaults it per Check type; state a field to pin it and leave the rest to the platform. (see [below for nested schema](#nestedatt--resource_profile))
- `secrets_refs` (Set of String) Secret references the Check may resolve at run time. References only — the platform stores no secret value on a Check, and neither does this resource. Placeholders are written `$${secret:<ref>}` and `$${<extract-name>}` in HCL: the doubled `$` escapes Terraform's own interpolation, and the platform receives a single one.
- `uptime` (Attributes) An uptime Check: one request or connection per run. Sets `type` to `uptime`. (see [below for nested schema](#nestedatt--uptime))
- `warm_pool` (Attributes) Warm capacity kept ready for a latency-sensitive Check. Removing the attribute clears it on the platform. (see [below for nested schema](#nestedatt--warm_pool))

### Read-Only

- `account_id` (String) The Account that owns the Check. Determined by the API key, not by configuration: a key is bound to exactly one Account.
- `id` (String) The Check's platform id (`checkId`), assigned on creation.
- `origin` (String) Which write path manages the Check: `terraform`, `api`, or `manifest`. Terraform plans this back to `terraform` whenever the platform reports anything else, so a dashboard edit that took ownership shows up as an ownership change in the plan (a Re-claim) beside whatever else it changed.
- `type` (String) `uptime`, `api`, or `browser`, derived from the spec attribute that is set. Not configurable: two sources for one fact is one source too many.

<a id="nestedatt--api"></a>
### Nested Schema for `api`

Required:

- `response_time_threshold_ms` (Number) Total response time above which a run counts as degraded, in milliseconds.
- `step` (Attributes List) The requests, **in order**. A list rather than a set, because an earlier step's `extract` feeds a later step's placeholders: reordering steps changes what the Check does. (see [below for nested schema](#nestedatt--api--step))

<a id="nestedatt--api--step"></a>
### Nested Schema for `api.step`

Required:

- `expected_status` (Number) The status this step must answer with.
- `method` (String) The HTTP method.
- `url` (String) The request URL. Placeholders are written `$${secret:<ref>}` and `$${<extract-name>}` in HCL: the doubled `$` escapes Terraform's own interpolation, and the platform receives a single one.

Optional:

- `assertion` (Attributes List) Assertions over the step's response. Ordered, because the platform stores them as a list and reports failures by index. (see [below for nested schema](#nestedatt--api--step--assertion))
- `body` (String) The request body. Placeholders are written `$${secret:<ref>}` and `$${<extract-name>}` in HCL: the doubled `$` escapes Terraform's own interpolation, and the platform receives a single one.
- `extract` (Attributes List) Values to pull out of the response for a later step to substitute as `$${<name>}`. (see [below for nested schema](#nestedatt--api--step--extract))
- `headers` (Map of String) Request headers. Give a credential as a secret reference, not a literal: a literal is stored on the platform, comes back masked, sits in Terraform state in clear, and — because a mask is not comparable — is never checked for drift. The provider warns at plan time when a header whose name looks like a credential carries a literal. Placeholders are written `$${secret:<ref>}` and `$${<extract-name>}` in HCL: the doubled `$` escapes Terraform's own interpolation, and the platform receives a single one.

<a id="nestedatt--api--step--assertion"></a>
### Nested Schema for `api.step.assertion`

Required:

- `comparator` (String) How to compare the source to `expected`.
- `source` (String) What to assert on — the status, a header, the body, or a JSON path into it.

Optional:

- `expected` (String) The expected value. Placeholders are written `$${secret:<ref>}` and `$${<extract-name>}` in HCL: the doubled `$` escapes Terraform's own interpolation, and the platform receives a single one.
- `path` (String) The path into the source, for a source that needs one.


<a id="nestedatt--api--step--extract"></a>
### Nested Schema for `api.step.extract`

Required:

- `name` (String) The placeholder name a later step substitutes.
- `path` (String) The path into the source.
- `source` (String) Where to read the value from.




<a id="nestedatt--browser"></a>
### Nested Schema for `browser`

Required:

- `max_execution_ms` (Number) Wall-clock budget for the script, in milliseconds.
- `script` (String) The script to run. Placeholders are written `$${secret:<ref>}` and `$${<extract-name>}` in HCL: the doubled `$` escapes Terraform's own interpolation, and the platform receives a single one.

Optional:

- `otel_enabled` (Boolean) Whether the run emits OpenTelemetry traces.


<a id="nestedatt--resource_profile"></a>
### Nested Schema for `resource_profile`

Optional:

- `compute` (String) The compute backend the platform runs the Check on.
- `memory_mb` (Number) Memory for the runner, in MB.
- `timeout_ms` (Number) Run timeout, in milliseconds.


<a id="nestedatt--uptime"></a>
### Nested Schema for `uptime`

Required:

- `mode` (String) `url` for an HTTP request, `tcp` for a connection, `heartbeat` for a Check the target reports in to.
- `target` (String) What to check: a URL for `url`, a host for `tcp`, an identifier for `heartbeat`. Placeholders are written `$${secret:<ref>}` and `$${<extract-name>}` in HCL: the doubled `$` escapes Terraform's own interpolation, and the platform receives a single one.

Optional:

- `connect_timeout_ms` (Number) Connection timeout, in milliseconds.
- `expected_status_range` (Attributes) The response status range that counts as up. Required when `mode` is `url`, which the provider checks at plan time. (see [below for nested schema](#nestedatt--uptime--expected_status_range))
- `heartbeat_interval_seconds` (Number) How often a `heartbeat` Check expects to be reported in to, in seconds.
- `port` (Number) Port for a `tcp` Check.

<a id="nestedatt--uptime--expected_status_range"></a>
### Nested Schema for `uptime.expected_status_range`

Required:

- `max` (Number) Highest status that counts as up, inclusive.
- `min` (Number) Lowest status that counts as up, inclusive.



<a id="nestedatt--warm_pool"></a>
### Nested Schema for `warm_pool`

Required:

- `min` (Number) Minimum number of warm runners.
