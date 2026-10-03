---
page_title: "soroush_alert_rule Resource - Soroush"
subcategory: ""
description: |-
  A Soroush Alert Rule: which Checks to watch, what counts as worth alerting on, and how often to say so.
  Reference the Checks a rule selects (soroush_check.<name>.logical_name or soroush_check.<name>.id) rather than naming them literally: the reference is what tells Terraform to create the rule after its Checks and destroy it before them.
---

# soroush_alert_rule (Resource)

A Soroush Alert Rule: which Checks to watch, what counts as worth alerting on, and how often to say so.

Reference the Checks a rule selects (`soroush_check.<name>.logical_name` or `soroush_check.<name>.id`) rather than naming them literally: the reference is what tells Terraform to create the rule after its Checks and destroy it before them.

## Example Usage

```terraform
# A complete, runnable root module declaring two Alert Rules over one Check.
#
# The Checks a rule selects are named through references, not string literals.
# That is not a style preference: a reference is the only thing that tells
# Terraform to create the rule after its Checks and destroy it before them. With
# a literal, Terraform is free to create the rule first, and the API rejects a
# rule that selects a Check that does not exist yet.

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

resource "soroush_check" "checkout_api" {
  project_id       = "shop"
  logical_name     = "checkout-api"
  interval_seconds = 60
  locations        = ["eu-central-1"]

  uptime = {
    mode   = "url"
    target = "https://shop.example.com/api/checkout/health"

    expected_status_range = {
      min = 200
      max = 299
    }
  }
}

# Select named Checks. Exactly one of `all`, `logical_names`, and `check_ids` may
# be set.
resource "soroush_alert_rule" "checkout_down" {
  project_id = "shop"

  check_selector = {
    # The reference is what orders this rule after the Check above.
    logical_names = [soroush_check.checkout_api.logical_name]
  }

  fire_on  = "down"
  severity = "critical"

  # The ceiling that keeps a flapping Check from becoming an alert storm.
  max_notification_rate = {
    max_notifications = 3
    window_seconds    = 3600
  }

  # Channel ids come from the dashboard: which channels exist is an
  # Account-scoped fact the API owns, and there is no channel resource.
  channels = ["ch_oncall_email"]

  # Third-party paging platforms, configured on the platform side.
  integrations = ["pagerduty"]

  # Both optional. Removing either attribute clears it on the platform.
  consecutive_failures = 2
  grouping_key         = "checkout"
}

# Select every Check in the Project, including ones added later. `all` is a
# standing subscription rather than a snapshot.
resource "soroush_alert_rule" "anything_degraded" {
  project_id = "shop"

  check_selector = {
    all = true
  }

  fire_on  = "degraded"
  severity = "low"

  max_notification_rate = {
    max_notifications = 1
    window_seconds    = 900
  }

  channels = ["ch_oncall_email"]

  # An `all` rule has no reference to any Check, so Terraform has no reason to
  # order it after one. That is fine here — an `all` selector names nothing that
  # has to exist first — but it is why a `logical_names` rule should always use a
  # reference.
  depends_on = [soroush_check.checkout_api]
}

output "checkout_down_rule_id" {
  description = "The platform id the rule was assigned, which is also its import id."
  value       = soroush_alert_rule.checkout_down.id
}
```

## Reference the Checks, do not name them

`check_selector.logical_names` and `check_selector.check_ids` take strings, and
Terraform cannot tell a string that happens to match a Check's name from any other
string. Write `soroush_check.checkout_api.logical_name` rather than
`"checkout-api"`: the reference is the only thing that orders the rule after its
Checks on create, and before them on destroy. With a literal, Terraform is free to
create the rule first, and the API rejects a rule selecting a Check that does not
exist yet.

An `all = true` selector references nothing by construction. If it must be ordered
after specific Checks, say so with `depends_on`.

## What Terraform state contains for this resource

State holds a clear-text copy of every attribute below: the Project, the selector
(and therefore the Check names or ids it lists), the fire-on condition, the
severity, the notification rate ceiling, the channel ids, the integration names,
the consecutive-failure threshold and grouping key, plus the computed `origin`,
`account_id`, and `id`.

State never holds notification **channel configuration** — the email addresses,
webhook URLs, or integration credentials behind a channel id. The API does not
return them, so the provider cannot record them; a rule references a channel by
id and nothing more. There are no secrets on this resource at all.

Use a remote backend with encryption at rest and restricted read access anyway:
the selector and grouping key describe your monitoring topology. And keep the
`api_key` in `SOROUSH_API_KEY` rather than in a `provider` block — state records
no provider configuration either way, but a saved plan file records a literal
`api_key` from HCL.

No attribute on this resource carries a `${…}` placeholder, so the `$${…}`
escaping rule that applies across `soroush_check` does not arise here.

## Clearing an optional

`consecutive_failures` and `grouping_key` are the two attributes a rule can hold
or not hold. Removing either from the configuration clears it on the platform —
the provider sends an explicit null rather than omitting the key, so "I removed
this" and "I did not mention this" do not collapse into the same request.

## Ownership: re-claim, and what a dashboard edit does

`origin` is computed and is meant to disagree with state. Every write this
provider makes declares `terraform`; a dashboard edit records `api`, and the next
`terraform plan` shows `origin` changing back — a **re-claim** — beside whatever
else that edit changed. Applying restores the configuration and takes management
back.

## Import

```shell
#!/usr/bin/env bash
# Import an existing Alert Rule by its platform id. The dashboard's Terraform
# section on the rule's edit page prints this exact command.
terraform import soroush_alert_rule.checkout_down rul_01HQ8Z0X6ABCDEFGHJKMNPQRS

# As with a Check, import writes only the id: the rule keeps the `origin` the
# platform holds, and the next plan proposes the change to `terraform`. Applying
# a manifest-origin rule's plan removes it from deployment-manifest
# reconciliation permanently.
terraform plan
```

Import writes the `id` and nothing else, so the rule keeps whatever `origin` the
platform holds and the *next* plan proposes the re-claim. Adoption is a change you
read and approve.

~> **Importing a manifest-origin rule is one-way.** A rule deployed from a Soroush
deployment manifest carries `origin = "manifest"`. Once imported and applied, its
origin is `terraform` and manifest reconciliation **stops covering it for good**:
the next `soroush deploy` reports it as a conflict rather than a change, and will
neither update nor delete it. There is no un-import — remove it from the manifest
and declare it here deliberately, or leave it where it is.

<!-- schema generated by tfplugindocs -->
## Schema

### Required

- `check_selector` (Attributes) Which Checks the rule applies to. Set exactly one of `all`, `logical_names`, and `check_ids`. (see [below for nested schema](#nestedatt--check_selector))
- `fire_on` (String) The result condition that fires the rule.
- `max_notification_rate` (Attributes) The ceiling that keeps a flapping Check from becoming an alert storm. (see [below for nested schema](#nestedatt--max_notification_rate))
- `project_id` (String) The Project the rule belongs to. Changing it replaces the rule: the API rejects `projectId` in a `PATCH` as immutable.
- `severity` (String) The severity carried into notifications, and mapped onto each integration's own scale.

### Optional

- `channels` (Set of String) Notification channel ids to notify. Which channels exist is an Account-scoped fact the API owns.
- `consecutive_failures` (Number) Consecutive failing runs required before the rule fires. Removing the attribute clears it on the platform.
- `grouping_key` (String) Groups alerts that share this key into one incident. Removing the attribute clears it on the platform.
- `integrations` (Set of String) Third-party paging and incident platforms to notify.

### Read-Only

- `account_id` (String) The Account that owns the rule. Determined by the API key, not by configuration.
- `id` (String) The rule's platform id (`ruleId`), assigned on creation.
- `origin` (String) Which write path manages the rule: `terraform`, `api`, or `manifest`. Terraform plans this back to `terraform` whenever the platform reports anything else, so an ownership change is visible in the plan (a Re-claim).

<a id="nestedatt--check_selector"></a>
### Nested Schema for `check_selector`

Optional:

- `all` (Boolean) Set to `true` to select every Check in the Project. Only `true` is meaningful: to select nothing, remove the rule.
- `check_ids` (Set of String) Select Checks by id. Prefer `soroush_check.<name>.id` references over literals, for the same ordering reason.
- `logical_names` (Set of String) Select Checks by `logical_name`. A set: selection is membership, so the order carries nothing. Prefer `soroush_check.<name>.logical_name` references over literals — a literal gives Terraform no reason to order the rule after the Check.


<a id="nestedatt--max_notification_rate"></a>
### Nested Schema for `max_notification_rate`

Required:

- `max_notifications` (Number) Notifications allowed per window.
- `window_seconds` (Number) The window, in seconds.
