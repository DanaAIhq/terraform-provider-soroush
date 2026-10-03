---
page_title: "soroush_inference_configuration Resource - Soroush"
subcategory: ""
description: |-
  Where this Account's AI inference runs, and on whose AWS bill: in Soroush's own deployment account (soroush_hosted, the default for every Account that configures nothing) or in an AWS account you own (customer_hosted).
  There is exactly one inference configuration per Account, so this resource is a singleton: declare it once. Applying it replaces the whole record, so in customer_hosted mode an omitted model_pin is a removed pin. For a customer_hosted target the apply fails unless Soroush can assume your role and invoke every model named. That is deliberate: a configuration that cannot serve a generation should not be recorded as though it could.
  Setting this up takes one apply, but the pieces have to be built in an order the soroush_inference_configuration data source exists to make possible — it reads the External ID before any role exists, so the modules/inference-role/ module can create the role and this resource can consume its ARN, all in one plan. See that data source.
  Requires an admin API key. Every route behind this resource is admin-only, so an editor key that manages every other resource in this provider gets a 403 here.
---

# soroush_inference_configuration (Resource)

Where this Account's AI inference runs, and on whose AWS bill: in Soroush's own deployment account (`soroush_hosted`, the default for every Account that configures nothing) or in an AWS account you own (`customer_hosted`).

There is exactly one inference configuration per Account, so this resource is a singleton: declare it once. Applying it replaces the whole record, so in `customer_hosted` mode an omitted `model_pin` is a removed pin. For a `customer_hosted` target the apply **fails** unless Soroush can assume your role and invoke every model named. That is deliberate: a configuration that cannot serve a generation should not be recorded as though it could.

Setting this up takes one apply, but the pieces have to be built in an order the `soroush_inference_configuration` **data source** exists to make possible — it reads the External ID before any role exists, so the `modules/inference-role/` module can create the role and this resource can consume its ARN, all in one plan. See that data source.

**Requires an `admin` API key.** Every route behind this resource is admin-only, so an `editor` key that manages every other resource in this provider gets a `403` here.

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

## This one needs an `admin` API key

Every route behind this resource is admin-only. An **editor** key — the key that
manages every `soroush_check` and `soroush_alert_rule` in this provider, and the
one this provider's own index page recommends for a pipeline — is refused here
with a `403`.

That is the most likely first failure in practice, and it does not look like a
permissions problem when it arrives: the credential that runs the rest of your
Terraform simply stops working at this resource. Mint an admin key on the
dashboard's **API keys** page, or with `POST /v1/api-keys`.

An admin key also carries the right to mint further keys, so handing one to the
pipeline that manages your monitors is a wider grant than that pipeline needs.
Configuring inference is a one-off, and running it from its own workspace with
its own credential keeps the wider key out of the workspace that does not need
it.

## One record per Account, so declare it once

An Account has exactly one inference configuration, the Account follows from the
API key, and the only write the platform offers is a whole-record replace. This
resource is therefore a singleton: two declarations in one Account are two
configurations fighting over one record, each apply undoing the last.

`mode` is the only attribute always required. Four more are required **when
`mode` is `customer_hosted`**, and the provider says so at plan time rather than
letting the apply start and fail:

- `role_arn` — the role in your account Soroush assumes. Its name must begin
  `soroush-inference-` and carry no IAM path, because Soroush's inference
  principal may assume only `arn:aws:iam::*:role/soroush-inference-*`.
- `region` — the one region inference runs in, and the region every profile
  identifier below is resolved in.
- `primary_profile` — every generation's first attempt.
- `escalation_profile` — every self-correction attempt. Required alongside
  `primary_profile` in **either** mode: half a pair is what makes an escalation
  resolve to nothing at the moment it is needed.

A value Terraform has not resolved yet counts as present, which is what lets
`role_arn` be a module output — the whole point of the worked example above.

`model_pin` is a set **keyed on `source_type`**. Each source type may appear at
most once, checked at plan time, because the wire format is an object keyed by
source type and two `openapi` blocks would silently collapse to whichever one Go
iterated to last. A block naming neither `primary` nor `escalation` is rejected
too: it resolves to exactly the same models as no pin at all.

Five attributes are computed and cannot be set: `external_id`,
`inference_principal_arn`, `verification_state`, `inference_failure`, and
`account_id`.

Because every write is a whole-record replace, **an omitted `model_pin` is a
removed pin** when `mode` is `customer_hosted`. The customer fields are the
exception, and only in one direction: `role_arn`, `region`, and both profile
selections are retained by the platform when you switch back to `soroush_hosted`,
so removing one of those attributes does not clear it — the API offers no way to —
it leaves whatever is stored in place.

The pins are retained across that switch too, so that switching forward again
needs no re-entry, and a `soroush_hosted` configuration can keep its `model_pin`
blocks: they are sent and tracked like the customer fields, and they are inert
until you switch forward. Removing them in that mode does not clear the retained
pins, although the plan shows them going: the resource stops tracking them rather
than proposing, on every plan, a deletion the API would not make. The next
`customer_hosted` apply replaces them with whatever the configuration states.

## An apply is a replace, and a `customer_hosted` apply is then verified

`Create` and `Update` are the same calls in the same order, because there is
nothing a create does on a singleton that an update does not. Both `PUT` the
whole record. When `mode` is `customer_hosted`, both then `POST` the
verification. The replace is what the platform validates and persists; the
verification is what proves Soroush can assume your role and invoke every model
you named.

**A verification that does not pass is an error.** The apply fails, and no state
is recorded — rather than reporting success over a configuration that cannot
serve a single generation. Nothing is lost by failing: the platform has the
candidate and the evidence either way, and a `customer_hosted` replace it could
not verify leaves the Account's mode exactly where it was, so document processing
carries on wherever it was already happening. Fix the named fault in your own AWS
account and apply again; the request was never invalid.

Every `customer_hosted` apply verifies, even when the same configuration verified
before. A trust policy and a model's regional availability can both change while
a configuration sits unused, so a `verification_state` inherited from whenever
somebody last asked is not a measurement. Each verification costs one small model
invocation per distinct identifier, on your bill, carrying platform-authored
synthetic content and never one of your documents. The platform verifies the
replace before the mode takes effect, and the provider then requests one more
verification, so a successful `customer_hosted` apply verifies twice.

A `soroush_hosted` apply is the replace alone. The switch applies immediately,
with no verification, from any state including a failed one, which is how you
restore generation after revoking Soroush's access without repairing the role
first. `verification_state` and `inference_failure` then keep describing the
customer configuration the platform retained, as last recorded, and switching
forward again verifies it.

`verification_state` and `inference_failure` are computed and deliberately **not**
held to their stored values, so whatever Soroush has recorded about your
configuration shows up in `terraform plan`. That is also the limit of what `plan`
can show. A refresh reads the configuration and never probes your account, and
Soroush does not re-verify on a schedule. You can delete the role, drop Soroush's
principal from its trust policy, or narrow the permission policy at any moment
without telling us, and `plan` shows it only once something has recorded it:

- a verification records every kind of revocation;
- a generation that cannot assume the role records that, and fails with the
  reason;
- a generation refused by a narrowed permission policy reports it on the
  generation request, not on this configuration, so only a verification brings it
  here.

After changing the role, request verification with **Request verification** on
the dashboard's Inference page or `soroush inference verify`. A throttled probe
reports `unverified` rather than `failed`: "we could not tell yet" is not "your
configuration is wrong".

## Destroying returns the Account to `soroush_hosted`

There is no `DELETE` route, because an Account cannot *not* have an inference
configuration — absence of a record **is** `soroush_hosted`. So a destroy here
writes rather than forgets.

Dropping the resource from state and calling it destroyed would leave the Account
still routing every document into your AWS account, on your bill, with Terraform
reporting that it manages nothing: the orphan would be the live configuration,
not a record of one. Instead, `terraform destroy` sets the mode back to
`soroush_hosted`. That applies with no verification, from any state including a
failed one — which is also how you restore generation after revoking Soroush's
access without repairing the role first.

It is cheap to undo. The platform retains the role ARN, the region, both profile
selections, the pins, **and the External ID**, so re-applying later needs nothing
from you and your trust policy never breaks in the meantime.

Destroying a resource that is already `soroush_hosted` writes nothing at all. The
replace would change no setting and still append a change record, and an audit
trail full of entries that changed nothing is an audit trail nobody reads.

A destroy does move your document processing back into Soroush's account. That is
a consent boundary, crossed deliberately, with an audit record naming the
credential that crossed it.

## No import, and nothing to import

`terraform import` is not supported here, and there is nothing it would do. A
singleton reached through the API key has no id to name, and adopting an existing
configuration is just declaring this resource and applying: the write is a
whole-record replace, so the apply reconciles whatever the Account holds to
whatever you wrote. What it costs, for a `customer_hosted` declaration, is the
verification on the way past.

A failed apply needs no import recovery either. A replace that failed cannot have
left a second configuration behind, so the fix is another apply rather than the
`terraform import` dance `soroush_check` documents.

## What Terraform state contains for this resource

State holds a clear-text copy of every attribute below: the mode, the role ARN,
the region, both profile selections and every model pin, plus the five computed
values — `external_id`, `inference_principal_arn`, `verification_state`, the
recorded `inference_failure`, and `account_id`.

No attribute on this resource carries a secret value or a `${…}` placeholder, and
nothing here comes back masked, so neither the `$${…}` escaping rule nor the
masked-value drift caveat that applies across `soroush_check` arises. What state
does hold is the **External ID**, in the clear, and that is worth stating in both
halves:

- `external_id` is **deliberately not marked `Sensitive`**. It authenticates
  nothing on its own — an attacker would also have to *be* Soroush's inference
  principal — and an administrator cannot write the trust-policy condition
  without reading the value, which masking it in plan output would prevent.
- **A Terraform state file therefore holds it in clear text.** Use a remote
  backend with encryption at rest and restricted read access. That obligation is
  the reason the not-sensitive choice is acceptable rather than merely
  convenient; the two halves only hold together.

Rotating the External ID is an operator action taken with a human watching:
**Rotate External ID** on the dashboard's Inference page, or
`POST /v1/inference-configuration/rotate-external-id`. Neither this resource nor
the `soroush inference` CLI rotates it. A rotation stops customer-hosted
inference until the trust policy names the new value, which is not an outcome a
re-run of CI should be able to produce.

Keep the `api_key` in `SOROUSH_API_KEY` rather than in a `provider` block, as
everywhere else in this provider: state records no provider configuration either
way, but a saved plan file records a literal `api_key` from HCL — and here that
literal is an admin key.

<!-- schema generated by tfplugindocs -->
## Schema

### Required

- `mode` (String) `soroush_hosted` to run inference in Soroush's deployment account on Soroush's bill, or `customer_hosted` to run it in your own account, in your own region, on your own bill.

Switching to `customer_hosted` re-runs role assumption and a capability probe against every model named, **every time**, even where the same configuration verified before: a trust policy and a model's regional availability can both change while a configuration sits unused. Switching to `soroush_hosted` applies immediately with no verification, from any state — including a failed one, which is what lets you restore generation after revoking Soroush's access without repairing the role first.

### Optional

- `escalation_profile` (String) The Bedrock inference profile every self-correction attempt targets. Required when `mode` is `customer_hosted`, and required together with `primary_profile`: a pair with one member is what makes an escalation resolve to nothing at the moment it is needed.

Must be an Amazon Bedrock inference profile or foundation-model identifier — never a fine-tuned, distilled, custom-imported, or provisioned-throughput model, in either mode, because Soroush cannot evidence what an adapted model was adapted on.

A `global.`-prefixed profile is **refused** here: it may route the request outside the geography of the region you named, which needs an explicit acknowledgement recorded against that exact identifier, and acknowledging it is an affirmative decision made in the dashboard or the CLI rather than a line of committed HCL. Name a single-geography profile — `us.`, `eu.`, `apac.` — that your region serves.
- `model_pin` (Attributes Set) Per-source-type model overrides. A set keyed on `source_type`: each source type may appear at most once, which the provider checks at plan time.

Each tier falls back independently — pin `primary` for `openapi` and leave its `escalation` to `escalation_profile` if that is what you want — and a source type with no pin at all resolves to the two default profiles, which is a documented fallback rather than a failure.

Every pinned identifier must be covered by your role's permission policy: the platform probes each distinct identifier at configuration time, so a pin naming a model the policy does not admit fails the apply rather than the first generation that resolves to it.

In `soroush_hosted` mode the pins are inert, and the platform retains them so that switching to `customer_hosted` again needs no re-entry. A `soroush_hosted` configuration can keep its `model_pin` blocks: they are sent and tracked like `role_arn`, `region`, and the profiles. Removing them in that mode does not clear the retained pins, although the plan shows them going: this resource stops tracking them rather than proposing, on every plan, a deletion the API would not make. The next `customer_hosted` apply replaces them with whatever the configuration states. (see [below for nested schema](#nestedatt--model_pin))
- `primary_profile` (String) The Bedrock inference profile every generation's first attempt targets. Required when `mode` is `customer_hosted`, and required together with `escalation_profile` in either mode.

Must be an Amazon Bedrock inference profile or foundation-model identifier — never a fine-tuned, distilled, custom-imported, or provisioned-throughput model, in either mode, because Soroush cannot evidence what an adapted model was adapted on.

A `global.`-prefixed profile is **refused** here: it may route the request outside the geography of the region you named, which needs an explicit acknowledgement recorded against that exact identifier, and acknowledging it is an affirmative decision made in the dashboard or the CLI rather than a line of committed HCL. Name a single-geography profile — `us.`, `eu.`, `apac.` — that your region serves.
- `region` (String) The AWS region in your account that inference runs in. Required when `mode` is `customer_hosted`.

Checked for syntax here and for capability by the platform: whether the region actually serves the inference profiles you named is answered by a probe against your own account at configuration time, not by a pattern. Retained across a switch to `soroush_hosted`, like `role_arn`.
- `role_arn` (String) The IAM role in **your** AWS account that Soroush assumes to invoke models. Required when `mode` is `customer_hosted`.

Its name must begin with `soroush-inference-` and carry no IAM path, because Soroush's inference principal is permitted to assume only `arn:aws:iam::*:role/soroush-inference-*` — a role named anything else cannot be assumed at all. The `modules/inference-role/` module names it `soroush-inference-<account_id>` for you.

Optional **and** computed, because the platform retains the ARN when you switch back to `soroush_hosted` so that switching forward again needs no re-entry. Removing the attribute therefore does not clear it — the API offers no way to — it leaves whatever is stored in place.

### Read-Only

- `account_id` (String) The Soroush Account this configuration belongs to — the `soroush-inference-<account_id>` suffix your role's name must carry. Determined by the API key, not by configuration.

Null if the API response carries no Account id. The `soroush_inference_configuration` data source warns when that happens, which is where it matters: the role module is wired to the data source's `account_id`, not to this one.
- `external_id` (String) The `sts:ExternalId` your role's trust policy must condition on. Minted by Soroush, and retained across every mode change so that switching away and back does not break your trust policy.

**Not marked sensitive, deliberately.** It is not a credential: it authenticates nothing on its own, because an attacker would also have to *be* Soroush's inference principal. It is returned in the clear for one reason — an administrator cannot write the trust-policy condition without reading it — and masking it in plan output would break that.

It does mean a **Terraform state file holds this value in clear text**, as it holds every attribute on this resource. Use a remote backend with encryption at rest and restricted read access. Rotating it is an operator action taken with a human watching (**Rotate External ID** on the dashboard's Inference page, or `POST /v1/inference-configuration/rotate-external-id`), not something this resource or the CLI does: a rotation stops customer-hosted inference until the trust policy names the new value, which is not an outcome a re-run of CI should be able to produce.
- `inference_failure` (Attributes) The recorded reason customer-hosted inference cannot run with this configuration, or absent when there is none. Present here means the configuration itself is at fault — a role that no longer admits Soroush, a region that stopped serving a model — rather than one generation having gone wrong.

In `soroush_hosted` mode it is the fault last recorded against the retained customer configuration, kept across the switch. It does not affect Soroush-hosted generation. (see [below for nested schema](#nestedatt--inference_failure))
- `inference_principal_arn` (String) The one principal your role's trust policy must admit. A platform fact, identical for every Account, on this resource so that a trust policy can be written without hunting through documentation.
- `verification_state` (String) Whether Soroush has confirmed it can reach the models this configuration names: `verified`, `unverified`, or `failed`.

Refreshed on every read, and deliberately **not** held to its stored value, so whatever Soroush has recorded shows up in `terraform plan`. A read does not probe your account and nothing re-verifies on a schedule, so a revocation — a deleted role, or Soroush's principal dropped from its trust policy — appears here only after a verification or a generation has recorded it. A withdrawn `bedrock:InvokeModel` grant is recorded only by a verification; a generation reports it on the generation request instead. After changing the role, request verification on the dashboard or with `soroush inference verify`.

A throttled probe leaves this `unverified` rather than `failed`: "we could not tell yet" is not "your configuration is wrong".

In `soroush_hosted` mode this describes the customer configuration the platform retained, as last recorded. Switching back neither verifies it nor clears it, so a `failed` here does not affect Soroush-hosted generation; switching forward again re-verifies.

<a id="nestedatt--model_pin"></a>
### Nested Schema for `model_pin`

Required:

- `source_type` (String) Which kind of extracted document this pin applies to: `openapi`, `markdown`, `html`, or `text`. Determined by the platform's own content detection, never by whoever submitted the document.

Optional:

- `escalation` (String) The inference profile this source type's self-correction attempts target. Falls back to `escalation_profile` when absent.

Must be an Amazon Bedrock inference profile or foundation-model identifier — never a fine-tuned, distilled, custom-imported, or provisioned-throughput model, in either mode, because Soroush cannot evidence what an adapted model was adapted on.

A `global.`-prefixed profile is **refused** here: it may route the request outside the geography of the region you named, which needs an explicit acknowledgement recorded against that exact identifier, and acknowledging it is an affirmative decision made in the dashboard or the CLI rather than a line of committed HCL. Name a single-geography profile — `us.`, `eu.`, `apac.` — that your region serves.
- `primary` (String) The inference profile this source type's first attempt targets. Falls back to `primary_profile` when absent.

Must be an Amazon Bedrock inference profile or foundation-model identifier — never a fine-tuned, distilled, custom-imported, or provisioned-throughput model, in either mode, because Soroush cannot evidence what an adapted model was adapted on.

A `global.`-prefixed profile is **refused** here: it may route the request outside the geography of the region you named, which needs an explicit acknowledgement recorded against that exact identifier, and acknowledging it is an affirmative decision made in the dashboard or the CLI rather than a line of committed HCL. Name a single-geography profile — `us.`, `eu.`, `apac.` — that your region serves.


<a id="nestedatt--inference_failure"></a>
### Nested Schema for `inference_failure`

Read-Only:

- `error_class` (String) The AWS exception class, and never its message: an STS or Bedrock message can quote the request that provoked it, and that request carries your API documentation.
- `inference_profile_id` (String) The inference profile concerned.
- `kind` (String) Which stage failed: `not_verified`, `role_assumption_refused`, `external_id_rejected`, `region_unusable`, `profile_unavailable`, `access_denied`, `capability_unsupported`, `probe_throttled`, `probe_failed`, `refused_model_resource`, or `geography_unacknowledged`.
- `region` (String) The region the attempt targeted.
- `role_arn` (String) The role the attempt targeted.
