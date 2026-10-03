---
page_title: "soroush_inference_configuration Data Source - Soroush"
subcategory: ""
description: |-
  Reads the three values the modules/inference-role/ Terraform module needs in order to create the IAM role Soroush assumes for customer-hosted inference.
  This data source exists to break a dependency cycle, and it is worth knowing why before wiring it up. The role must trust Soroush under an External ID that Soroush generates; the soroush_inference_configuration resource must name the role the module creates. Each appears to need the other first.
  It resolves because the External ID is derived from nothing — not from the role ARN, not from your account id, not from anything a request carries — so it can be minted before any role exists. Reading it here does exactly that, idempotently: the first read on an Account mints and stores the value, every later read returns the same one. So the data source reads, the module creates, and the resource configures, all in one apply with no cycle.
  Takes no arguments: there is one inference configuration per Account, and the Account comes from the API key. Requires an admin API key, like the resource.
  ~> Reading this writes, once. On an Account that has never had an inference configuration, the first read persists the minted External ID. That is the one impure read on the Soroush API and it is deliberate — the value has to exist before the trust policy that names it can be written.
---

# soroush_inference_configuration (Data Source)

Reads the three values the `modules/inference-role/` Terraform module needs in order to create the IAM role Soroush assumes for customer-hosted inference.

**This data source exists to break a dependency cycle**, and it is worth knowing why before wiring it up. The role must trust Soroush under an External ID that Soroush generates; the `soroush_inference_configuration` resource must name the role the module creates. Each appears to need the other first.

It resolves because the External ID is derived from nothing — not from the role ARN, not from your account id, not from anything a request carries — so it can be minted before any role exists. Reading it here does exactly that, idempotently: the first read on an Account mints and stores the value, every later read returns the same one. So the data source reads, the module creates, and the resource configures, all in **one apply** with no cycle.

Takes no arguments: there is one inference configuration per Account, and the Account comes from the API key. Requires an `admin` API key, like the resource.

~> Reading this writes, once. On an Account that has never had an inference configuration, the first read persists the minted External ID. That is the one impure read on the Soroush API and it is deliberate — the value has to exist before the trust policy that names it can be written.

## Example Usage

```terraform
# Customer-managed inference, end to end: read, create, configure — in one apply.
#
# This is the sequence that matters, and the order is the whole point:
#
#   1. `data "soroush_inference_configuration"` reads the External ID, the principal ARN,
#      and your Soroush Account id out of Soroush. It takes no arguments and needs no role
#      to exist.
#   2. `module "soroush_inference_role"` creates the IAM role in YOUR AWS account,
#      trusting that principal under that External ID.
#   3. `resource "soroush_inference_configuration"` tells Soroush to use it.
#
# There is an apparent cycle here: the role must trust Soroush under an External ID
# Soroush generates, and Soroush must be told the ARN of a role that does not exist yet.
# It dissolves because the External ID is derived from nothing at all — not from the role
# ARN, not from your account id — so it can be minted and read before anything exists.
# The data source is what breaks the cycle, and this ordering is what uses it. One
# apply, no cycle, no two-stage bootstrap.
#
# Two providers, two accounts: `soroush` talks to the Soroush API, `aws` talks to your
# own AWS account. That is not an accident of packaging — the role is yours, in your
# account, on your bill, and Soroush never holds a credential for it.

terraform {
  # 1.9, higher than the >= 1.5 the other examples carry, because the inference-role
  # module needs it: its `profile_ids` validation reads the geography list out of the
  # module's inference-role-arns.json rather than transcribing it, and a `variable`
  # validation could not refer to a `local` before 1.9. The provider itself still works
  # on 1.5.
  required_version = ">= 1.9"

  required_providers {
    soroush = {
      source = "DanaAIhq/soroush"
      # The pin the Soroush dashboard renders. It admits every 0.x release from 0.1 on,
      # including v0.2.0, the first release with customer-managed inference.
      version = "~> 0.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# Set SOROUSH_API_KEY (an **admin** key — the inference configuration routes require it)
# and SOROUSH_API_URL rather than writing either here: a saved plan file records the
# literal values of a `provider` block.
provider "soroush" {}

# Your account, and the region inference will run in. It must match `local.region`
# below: that value is the region field of every inference-profile ARN in the role's
# policy, so a mismatch produces a role that plans clean and denies at invocation.
provider "aws" {
  region = local.region
}

locals {
  # One region, named once. `var`-free so this file is runnable as written.
  region = "us-east-1"

  # The models Soroush may invoke on your behalf, both served in `local.region`.
  # `primary` is every generation's first attempt; `escalation` is the larger model a
  # self-correction retry reaches for.
  primary_profile    = "us.amazon.nova-micro-v1:0"
  escalation_profile = "us.amazon.nova-2-lite-v1:0"

  # Pinning `openapi` generation to the primary model. A pin names an identifier the
  # role must also be able to invoke.
  openapi_pin = local.primary_profile
}

# ── 1. Read ───────────────────────────────────────────────────────────────────────
#
# Takes no arguments: there is one inference configuration per Account, and the Account
# comes from the API key.
#
# Reading this writes, once: on an Account that has never had an inference
# configuration, the first read mints and persists the External ID. That is deliberate —
# the value has to exist before the trust policy naming it can be written — and it is
# idempotent, so every later read returns the same value.
data "soroush_inference_configuration" "current" {}

# ── 2. Create the role, in your account ───────────────────────────────────────────
#
# `profile_ids` must be the UNION of every identifier Soroush may reach for: both
# selections and every pinned identifier. An identifier missing here is an
# `AccessDeniedException` on the generation that needs it — so it is derived from the
# same locals the resource below uses, rather than typed out twice.
module "soroush_inference_role" {
  # In your own configuration, use the Git source, pinned to a release:
  #
  #   source = "github.com/DanaAIhq/terraform-provider-soroush//modules/inference-role?ref=v0.2.0"
  #
  # Pin the ref rather than tracking the default branch: this module writes an IAM
  # policy, and an unpinned source is an IAM policy that can change under you between
  # two applies. The relative path below is what lets this example be validated in place.
  source = "../../modules/inference-role"

  external_id             = data.soroush_inference_configuration.current.external_id
  inference_principal_arn = data.soroush_inference_configuration.current.inference_principal_arn

  # Your Soroush Account id, which the role is named after. If the data source warns that
  # the API did not report it, pass the id from the dashboard here instead.
  soroush_account_id = data.soroush_inference_configuration.current.account_id

  region = local.region
  profile_ids = distinct([
    local.primary_profile,
    local.escalation_profile,
    local.openapi_pin,
  ])
}

# ── 3. Configure Soroush to use it ────────────────────────────────────────────────
#
# `apply` issues the write and then a verification: Soroush assumes the role and makes
# one small paid invocation per distinct identifier to prove it works. A verification
# failure is an **error**, so `apply` fails loudly rather than recording a configuration
# that cannot serve a generation. That paid probe is on your bill, and it sends only
# platform-authored synthetic content — never one of your documents.
resource "soroush_inference_configuration" "this" {
  mode = "customer_hosted"

  role_arn           = module.soroush_inference_role.role_arn
  region             = local.region
  primary_profile    = local.primary_profile
  escalation_profile = local.escalation_profile

  model_pin = [
    {
      source_type = "openapi"
      primary     = local.openapi_pin
    },
  ]
}

# What the role grants, visible without reading state. A policy nobody can see is a
# policy nobody reviews.
output "permission_policy_json" {
  description = "The inline policy IAM receives: bedrock:InvokeModel on four ARNs, two per profile."
  value       = module.soroush_inference_role.permission_policy_json
}

output "invocation_resource_arns" {
  description = "Two ARNs per profile — the inference profile, and the foundation model it routes to."
  value       = module.soroush_inference_role.invocation_resource_arns
}

# Reported by Soroush after the verification, not asserted by this configuration. A
# revocation Soroush has recorded — by a later verification, or by a generation that
# could not assume the role — turns this into a diff on the next `plan`.
output "verification_state" {
  description = "Whether Soroush could assume the role and invoke both profiles."
  value       = soroush_inference_configuration.this.verification_state
}
```

## The cycle this breaks

Customer-hosted inference needs two things built in two different AWS accounts,
and each of them appears to need the other first:

- The IAM role lives in **your** account, is created with the `aws` provider, and
  its trust policy has to condition on an `sts:ExternalId` that **Soroush** mints.
  So the role needs a value that lives in Soroush.
- The `soroush_inference_configuration` **resource** lives in Soroush, and has to
  name the ARN of a role that **does not exist yet**. So the resource needs a
  value your account creates.

Written as one resource that both read and wrote, that is a dependency cycle, and
no ordering of applies resolves it. Two-stage bootstraps — apply once to read a
value, edit the configuration, apply again — are the usual answer, and they are
the thing this data source exists to avoid.

It dissolves because the External ID is **derived from nothing**: not from the
role ARN, not from your AWS account id, not from anything a request carries. That
is a platform rule rather than an accident, so that nobody who learns the role ARN
can reconstruct the External ID — and a value derived from nothing can be minted
before anything exists. So it is readable first.

Read it here, let the `modules/inference-role/` module create the role trusting
Soroush under it, and let the resource name the module's output. **One apply, no
cycle**, and the example above is that sequence in full.

## Reading writes, once

On an Account that has never had an inference configuration, the first read mints
the External ID, persists it under a conditional write, and returns it. Every
later read returns the same value and writes nothing.

That is the one impure read on the Soroush API, and it is deliberate: the value
has to exist before the trust policy naming it can be written, which is the whole
mechanism above. It is idempotent, so it is safe in a plan, and safe to run from
as many workspaces as you like.

There is no not-found case for the configuration itself — every Account has one,
because absence *is* one. A `404` therefore does not mean "not configured"; it can
only mean the endpoint does not serve the inference-configuration routes at all,
and the diagnostic says so rather than resolving to nothing and pushing an empty
External ID into your trust policy.

## This one needs an `admin` API key

Like the resource, and for the same reason: every inference-configuration route is
admin-only. An **editor** key — the key that reads and manages every other
resource and data source in this provider — is refused here with a `403`.

Because this data source is read at plan time, that `403` is usually the *first*
thing an operator sees when they bring an editor key to this feature, before any
role has been created and before anything has been written. It is a credential
problem, not a configuration one.

## Three attributes, and why not the mode

This data source carries what the role module consumes and stops: `external_id`,
`inference_principal_arn`, and `account_id`. It reports no mode, no
`verification_state`, and no recorded failure — those belong to the resource that
manages them, and a data source offering them would invite a workspace to branch
on the state of a configuration it is in the middle of applying.

`account_id` is what the role's name is composed from. Soroush's inference
principal may assume only roles named `soroush-inference-<account_id>`, so wire
it into the module's `soroush_account_id`, as the example above does.

If a response carries no Account id, `account_id` is null and the data source
warns rather than failing the read, because the two values the cycle turns on are
unaffected. A module wired to a null value cannot compose the role name, so in
that case pass your Account id to the module explicitly. It is on the dashboard,
and it is the `account_id` of every `soroush_check` and `soroush_alert_rule` in
the same Account.

## What Terraform state contains for this data source

A data source result is recorded in state like any other, so state holds a
clear-text copy of all three values read back: the External ID, the inference
principal ARN, and the Account id. There are no secrets here in the platform's
sense — no attribute carries a secret value or a `${…}` placeholder, and nothing
comes back masked.

The External ID is the value worth being precise about, in both halves:

- `external_id` is **deliberately not marked `Sensitive`**. It authenticates
  nothing on its own — an attacker would also have to *be* Soroush's inference
  principal — and it exists to be read and pasted into a trust policy, which
  masking it would defeat. This data source's entire purpose is that an
  administrator, or a module, can read it.
- **A Terraform state file therefore holds it in clear text.** Use a remote
  backend with encryption at rest and restricted read access. That obligation is
  what makes the not-sensitive choice acceptable rather than merely convenient;
  neither half stands without the other.

Keep the `api_key` in `SOROUSH_API_KEY` rather than in a `provider` block, as
everywhere else in this provider: state records no provider configuration either
way, but a saved plan file records a literal `api_key` from HCL — and reaching
this data source at all means that literal is an admin key.

<!-- schema generated by tfplugindocs -->
## Schema

### Read-Only

- `account_id` (String) The Soroush Account the API key belongs to — the `soroush-inference-<account_id>` suffix your role's name must carry, because Soroush's inference principal may assume only roles named with that prefix. Wire it into the role module's `soroush_account_id`.

If the API response carries no Account id, this attribute is null and the data source warns rather than failing the read. Pass your Account id to the module explicitly in that case — it is on the dashboard and in every other resource's `account_id` — because a module wired to a null value cannot compose the role name.
- `external_id` (String) The `sts:ExternalId` your role's trust policy must condition on. Retained across every mode change, so a trust policy written once keeps working.

**Not marked sensitive, deliberately**: it authenticates nothing on its own — an attacker would also have to *be* Soroush's inference principal — and it exists to be read and pasted into a trust policy, which masking it would prevent.

A **Terraform state file holds this value in clear text**, as it holds every attribute a data source reads. Use a remote backend with encryption at rest and restricted read access.
- `inference_principal_arn` (String) The only principal your role's trust policy should admit. A platform fact, identical for every Soroush Account, read from the API rather than copied out of documentation so that it cannot go stale in your configuration.
