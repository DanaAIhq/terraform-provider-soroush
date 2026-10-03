---
page_title: "Provider: Soroush"
description: |-
  Manages Soroush synthetic monitoring Checks and Alert Rules, and the Account's inference configuration. Configure the provider with an API key minted from the Soroush dashboard's API keys page; an editor key is sufficient for the monitoring resources, and soroush_inference_configuration requires an admin key.
---

# Soroush Provider

Manages Soroush synthetic monitoring Checks and Alert Rules, and the Account's inference configuration. Configure the provider with an API key minted from the Soroush dashboard's **API keys** page; an `editor` key is sufficient for the monitoring resources, and `soroush_inference_configuration` requires an `admin` key.

## Example Usage

```terraform
# A complete, runnable root module that configures nothing but the provider.
#
# `terraform init && terraform plan` in this directory is the smallest possible
# check that the credential works: with no resources declared, a successful plan
# means the provider configured, and a failed one names which of the two inputs
# is missing.

terraform {
  # 1.5 is the floor this provider supports. It needs 1.0 to speak protocol 6 at
  # all — every nested attribute in the schema is a protocol-6 construct — but
  # 1.5 is the oldest minor still worth supporting, and it is the version the
  # `import` block below is written against.
  required_version = ">= 1.5"

  required_providers {
    soroush = {
      # Terraform normalises provider addresses to lowercase, so this is the same
      # address as `danaaihq/soroush`.
      source = "DanaAIhq/soroush"

      # The provider reports the version it was built at, so this constraint is
      # enforced against the installed artifact. Pre-1.0 means the schema may
      # still move: narrow this to `~> 0.1.0` once a configuration depends on a
      # specific shape.
      version = "~> 0.1"
    }
  }
}

# Both attributes are optional, and both are better left out.
#
#   api_key  — set SOROUSH_API_KEY instead. A saved plan file records the literal
#              values of a `provider` block, so a key written here ends up in any
#              plan artifact CI keeps. An environment variable never does.
#   endpoint — set SOROUSH_API_URL instead, or leave both unset to use the
#              default, https://api.soroush.v.majedi.ca.
#
# These are the Soroush CLI's own two variables, so one shell configures
# `soroush deploy` and `terraform apply` alike.
provider "soroush" {}
```

## Authentication

A Soroush API key is bound to exactly one Account, and the Account a resource
lands in follows from the key rather than from configuration. There is no
attribute for it, and the provider sends no account header: a key that named
another Account would be denied anyway.

Mint the key on the dashboard's **API keys** page, or with `POST /v1/api-keys`.
An **editor** key manages every Check and Alert Rule here, and is what a
monitoring pipeline should carry: an admin key additionally holds the right to
mint further keys, which is a capability that pipeline has no use for.

`soroush_inference_configuration` is the one exception, resource and data source
alike. Every inference-configuration route is **admin-only**, so the editor key
that manages everything else is refused there with a `403` — usually at plan
time, on the data source, before anything has been written. Configuring inference
is a one-off, so give it its own workspace and its own admin credential rather
than widening the key the rest of your Terraform runs with.

The [customer-managed inference guide](guides/customer-managed-inference.md)
covers that setup end to end: what the IAM role grants, how Soroush verifies it,
and what each failure means.

Supply it through the `SOROUSH_API_KEY` environment variable rather than the
`api_key` attribute. Both work, and the attribute is marked sensitive so
Terraform redacts it from plan output — but a **saved plan file** records the
literal values of a `provider` block, so a key written in HCL ends up in any plan
artifact your pipeline keeps. An environment variable never does.

`SOROUSH_API_URL` overrides the endpoint the same way. Both names are the Soroush
CLI's own, so one shell configures `soroush deploy` and `terraform apply` alike.

## What Terraform state contains

Terraform state is a full copy of every attribute this provider reads back, in
clear text. Concretely, for each resource:

| Resource | In state | Never in state |
|---|---|---|
| `soroush_check` | project and logical name, interval, locations, thresholds, retries, warm pool, resource profile, and the whole spec — request URLs, header names **and their values**, request bodies, browser scripts — plus secret **references**, `origin`, `account_id`, and `id` | a secret **value** — no attribute on this resource carries one; the Check's runtime state; run results |
| `soroush_alert_rule` | selector, channel ids, integration names, severity, fire-on condition, rate ceiling, grouping key, `origin`, `account_id`, `id` | notification channel configuration — the API never returns it |
| `soroush_inference_configuration` | mode, role ARN, region, both inference-profile selections, every model pin, and the computed `external_id` **in clear text**, `inference_principal_arn`, `verification_state`, recorded `inference_failure`, `account_id` | nothing is masked and no attribute carries a secret value; the data source of the same name records its three values the same way |
| the provider itself | nothing. Provider configuration is not state | the `api_key`, **when it comes from `SOROUSH_API_KEY`**. Supplied as an attribute in HCL it is still absent from state, but a saved plan file records it |

Two consequences worth acting on:

- **Use a remote backend with encryption at rest and restricted read access.**
  Anything you would not paste into a shared document — an internal hostname, a
  staging URL, a header value — is in the state file once it is in a Check, and
  your Account's External ID is in it once `soroush_inference_configuration` is.
  That last one is not marked sensitive on purpose, because an administrator has
  to read it to write the trust policy that conditions on it; this backend
  obligation is what makes that choice acceptable.
- **Never write a credential into a header value.** Use a secret reference. A
  literal is stored on the platform, comes back masked, sits in state in clear,
  and is not drift-detectable (see below). The provider warns at plan time when a
  header whose *name* looks like a credential carries a literal value.

## Secret references and the `$${…}` escape

The platform resolves two kinds of placeholder at run time: `${secret:<ref>}`
for a secret reference, and `${<name>}` for a value an earlier API step
extracted. Both share HCL's own interpolation syntax, so in Terraform they are
written with a doubled dollar:

```hcl
headers = {
  "X-Api-Key"     = "$${secret:shop/checkout-token}"
  "Authorization" = "Bearer $${session_token}"
}
```

Terraform hands the provider a single `$`, which is what the platform stores and
the runner resolves. Written with one `$` you get an HCL error about an unknown
object named `secret` — an error, not a leak, which is the point of leaving the
escape visible rather than guessing at it.

Every string attribute that can carry a placeholder repeats this note in its own
description.

## Masked values are not drift-detectable

The API masks certain values on read, answering `***REDACTED***` instead of the
stored value. The provider keeps the value already in state for any attribute
that comes back masked, because writing the mask into state would make every
subsequent plan propose changing a real value to the literal string
`***REDACTED***`.

The cost is exact and worth stating plainly: **a masked value that changes on the
platform cannot be detected as drift.** The provider has nothing to compare. If
someone edits a masked header value in the dashboard, `terraform plan` stays
empty and the next apply does not restore it. This is the strongest reason to
keep credentials in secret references, where the reference — not the value — is
what state holds and compares.

## Provenance, and sharing an Account with other tools

Every Check and Alert Rule on the platform carries an `origin`: `terraform`,
`api` (the dashboard or a direct API call), or `manifest` (a `soroush deploy`).
This provider declares `terraform` on every write, and the platform records it.

- The dashboard shows the badge, and warns before letting someone edit a
  Terraform-managed monitor.
- A dashboard edit takes ownership: `origin` becomes `api`. Terraform notices on
  the next refresh and plans an ownership change — a **re-claim** — beside
  whatever else changed. The apply restores your configuration and takes
  management back.
- A `soroush deploy` leaves Terraform-managed entities alone entirely.

<!-- schema generated by tfplugindocs -->
## Schema

### Optional

- `api_key` (String, Sensitive) A Soroush API key. Falls back to the `SOROUSH_API_KEY` environment variable, which is the recommended way to supply it: a saved plan file records the literal values of a `provider` block, and an environment variable never reaches Terraform state or a plan file.
- `endpoint` (String) The Soroush API base URL. Falls back to the `SOROUSH_API_URL` environment variable, then to `https://api.soroush.v.majedi.ca`.
