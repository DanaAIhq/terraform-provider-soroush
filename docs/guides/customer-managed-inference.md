---
page_title: "Customer-managed inference"
subcategory: ""
description: |-
  Run Soroush's Bedrock model calls in your own AWS account, in a region and on models you choose, on your own bill. What it changes, what you grant, setup from the dashboard, the CLI, or Terraform, verification, cost, and troubleshooting.
---

# Customer-managed inference

When Soroush drafts a Check from your API documentation, it calls a model on Amazon
Bedrock. By default that call runs in Soroush's AWS account. Customer-managed inference
moves it into yours: Soroush assumes an IAM role you create and calls Bedrock in your
AWS account, in a region you name, against models you name, on your AWS bill.

It is opt-in, set per Soroush Account by an admin, and you can switch back at any time.

- [What it is](#what-it-is)
- [Prerequisites](#prerequisites)
- [What you grant](#what-you-grant)
- [Setup](#setup)
- [Verification](#verification)
- [What you see in your AWS account](#what-you-see-in-your-aws-account)
- [Switching back](#switching-back)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)

## What it is

Every Soroush Account has one inference mode:

| | `soroush_hosted` (default) | `customer_hosted` |
|---|---|---|
| AWS account the model call runs in | Soroush's | Yours |
| Region | `eu-central-1` | One region you name |
| Models | Soroush's default model pair, on EU (`eu.`) inference profiles | Models you name, optionally per source type |
| Inference bill | Soroush's | Yours |
| CloudTrail record of the model calls | In Soroush's account | In your account |
| Setup | None | One IAM role in your account |

An Account is in `soroush_hosted` until an admin changes it, and an Account that
configures nothing stays there.

### What moves, and what stays in Soroush

Only the credential and the endpoint of the Bedrock call move. In `customer_hosted`
mode, Soroush signs each call with a short-lived session for your role and sends it to
Bedrock in your region. Everything else is identical in both modes and stays in Soroush:

- prompt construction, and the schema the model must answer in, which it returns
  through a single forced tool call;
- the correction loop: the first attempt uses your primary model, and each correction
  attempt after a draft fails validation uses your escalation model;
- validation of every draft;
- storage. Source documents, drafts, generation requests and audit records stay in
  Soroush's AWS account in `eu-central-1`, scoped to your Account, encrypted, and kept
  for the same retention periods as in the default mode.

Soroush deploys nothing into your account. What reaches it is the model call itself,
whose prompt carries the extracted text of the document being processed.

### When to use it

- You have standardised on a particular Bedrock model.
- You must process data in a particular geography.
- You want model calls billed to your own AWS account, at your own AWS pricing.
- You need evidence of where your API documentation was processed: the model calls
  appear in your own CloudTrail.

It is not a fit if documentation must never leave your network. Soroush still receives,
stores and extracts your documents in its own account, and the extracted text travels
to Bedrock in yours. If none of the reasons above applies, the default needs no setup
and costs you nothing for inference.

## Prerequisites

- **A Soroush `admin`.** Reading and changing the inference configuration is admin-only
  on every surface. Editors and viewers see an explanation on the dashboard page
  instead, and the API refuses them with `403`. The CLI, the API and Terraform need an
  admin credential, such as an admin API key minted on the dashboard's **API keys**
  page (see [Authentication](../index.md#authentication)). Editors can still generate,
  in whichever mode an admin configured.
- **An AWS account you own**, in the standard `aws` partition, where you can create an
  IAM role. Soroush refuses a role in its own AWS account, and a role in AWS China or
  AWS GovCloud cannot be assumed from Soroush's account.
- **Bedrock model access** in that account and region for every model you name. Each
  model must support a forced tool call. Verification checks both before the mode
  changes.
- **Terraform 1.9 or later** if you use the `modules/inference-role` module. The
  provider itself works on 1.5.

### Models and inference profiles

You name one region and two defaults: a **primary** identifier for every first attempt
and an **escalation** identifier for every correction attempt. You can pin either tier
per source type: `openapi`, `markdown`, `html`, or `text`. Soroush takes the source type
from the content it detected, never from the request, and a source type without a pin
uses the defaults. Identifiers are case-sensitive and passed to Bedrock as written.

| Identifier | How Soroush handles it |
|---|---|
| A single-geography inference profile with a `us.`, `eu.`, or `apac.` prefix, such as `us.amazon.nova-micro-v1:0` | Accepted. It doesn't have to be `eu.`; verification confirms your region serves it. |
| A bare foundation-model id, such as `amazon.nova-micro-v1:0` | Accepted. Many models are served only through an inference profile, and verification then fails with `profile_unavailable`. |
| A `global.` inference profile | Accepted only with an explicit acknowledgement that requests using it may run outside your region's geography. Its foundation-model ARN in the permission policy has region `*`. The acknowledgement is recorded with your identity and the time, covers that exact identifier only, and is never given by default; a changed identifier needs a new one. You can give it on the dashboard or in a CLI document. The Terraform provider has no way to give it, so a `global.` identifier fails a Terraform apply. Soroush's own `soroush_hosted` inference never uses a `global.` profile. |
| An inference profile with any other geography prefix | Soroush reads the first segment as a model provider, so the rendered policy lacks the inference-profile ARN and verification fails with `access_denied`. |
| A fine-tuned or distilled model (`custom-model/`), a custom-imported model (`imported-model/`), provisioned throughput (`provisioned-model/`), or anything that isn't a Bedrock identifier | Refused in either mode, because Soroush can't evidence what an adapted model was adapted on. |
| An empty identifier, one with surrounding whitespace, or a bare geography such as `eu` or `eu.` | Refused as malformed. |

## What you grant

One IAM role in your account, with a trust policy and one inline permission policy.
Nothing else.

### Role name

The role's name must start with `soroush-inference-`, and the role must have no IAM
path. Soroush's inference principal may assume only
`arn:aws:iam::*:role/soroush-inference-*`, so a role outside that pattern can't be
assumed at all, and Soroush refuses its ARN when you save. The role policy Soroush
renders, and the `modules/inference-role` module, name the role
`soroush-inference-<Account id>`, using your Soroush Account id rather than an AWS
account id.

### Trust policy

One statement, one principal, one action, one condition:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::444455556666:role/soroush-inference-principal"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "sor_ext_…"
        }
      }
    }
  ]
}
```

- **Principal:** Soroush's inference principal, one role in Soroush's AWS account and
  the same for every Soroush Account. The account id above is a placeholder: copy the
  real ARN from Soroush (see [where to get the exact documents](#where-to-get-the-exact-documents)).
- **Condition:** your Account's External ID, which Soroush generates. The condition is
  required: verification checks that the role can't be assumed without it, and refuses
  the configuration if it can.

### Permission policy

`bedrock:InvokeModel` and no other action, on two ARNs for each inference profile
Soroush may call. For `us.amazon.nova-micro-v1:0` and `us.amazon.nova-2-lite-v1:0` in
`us-east-1`, in AWS account `111122223333`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel"],
      "Resource": [
        "arn:aws:bedrock:us-east-1:111122223333:inference-profile/us.amazon.nova-micro-v1:0",
        "arn:aws:bedrock:us-*::foundation-model/amazon.nova-micro-v1:0",
        "arn:aws:bedrock:us-east-1:111122223333:inference-profile/us.amazon.nova-2-lite-v1:0",
        "arn:aws:bedrock:us-*::foundation-model/amazon.nova-2-lite-v1:0"
      ]
    }
  ]
}
```

| You name | The policy must allow |
|---|---|
| `us.<model-id>` | `arn:aws:bedrock:<region>:<your-account-id>:inference-profile/us.<model-id>` and `arn:aws:bedrock:us-*::foundation-model/<model-id>` |
| `eu.<model-id>` | the inference-profile ARN, and `arn:aws:bedrock:eu-*::foundation-model/<model-id>` |
| `apac.<model-id>` | the inference-profile ARN, and `arn:aws:bedrock:ap-*::foundation-model/<model-id>` (`ap-*`, not `apac-*`) |
| `global.<model-id>` | the inference-profile ARN, and `arn:aws:bedrock:*::foundation-model/<model-id>` |
| a bare `<model-id>` | `arn:aws:bedrock:<region>::foundation-model/<model-id>` only |

- A cross-region inference profile authorizes against the profile ARN and against the
  foundation-model ARN in whichever region the profile routes to. A policy naming only
  the profile applies cleanly, then fails the first call with `AccessDeniedException`.
- Foundation-model ARNs have an empty account field. Their region field is the only
  wildcard in the policy; model ids are always exact.
- List every identifier Soroush may call: both defaults and every pinned identifier.
- Soroush calls `Converse` without streaming, which authorizes as `bedrock:InvokeModel`.
  The policy grants no streaming, listing, model-customization, or CloudTrail action.

### Where to get the exact documents

Soroush renders both documents for your Account:

| Source | What it gives you |
|---|---|
| Dashboard, **Inference** page | The External ID and the Inference Principal, always. After a role ARN, region and profiles are saved, also the role name, the trust policy, the permission policy, and a Terraform snippet, each with a copy control. |
| `soroush inference get` | The External ID and the inference principal ARN, which is all the trust policy needs. The CLI doesn't render the permission policy. |
| `GET /v1/inference-configuration/role-policy` | `rolePolicy`, with `roleName`, `trustPolicy`, `permissionPolicy`, `terraformModule`, and an `advisory` when your region or profiles changed after the last passing verification. It answers `409` until a role ARN, region and profiles are saved. `GET /v1/inference-configuration` returns `externalId`, `inferencePrincipalArn` and `accountId` at any time. |
| The `soroush_inference_configuration` data source, with `modules/inference-role` | The data source reads `external_id`, `inference_principal_arn` and `account_id`. The module names the role from `account_id`, builds both policies from the other two, and outputs `trust_policy_json`, `permission_policy_json` and `invocation_resource_arns`. |

## Setup

Every path follows the same order:

1. **Read the configuration.** The first read creates your Account's External ID; later
   reads return the same value.
2. **Create the role** in your account, with the trust policy.
3. **Attach the permission policy.**
4. **Save the configuration** with mode `customer_hosted`. Soroush
   [verifies](#verification) it, and switches the mode only if verification passes.

The permission policy's ARNs depend on the region and profiles you choose, so the
dashboard and the API render it only after you save them. Either write it from the
table above before step 4, or save first: verification then fails with
`access_denied`, the mode doesn't change, and the rendered policy becomes available.
Attach it and save again.

### Dashboard

1. Sign in, select the Account to configure, and open **Inference** in the navigation.
   The page's first line names the Account id your role name uses.
2. From the **External ID** section, copy the **External ID** and the
   **Inference Principal**, and create the role `soroush-inference-<Account id>` in
   your account with the trust policy.
3. Under **Change the configuration**, set **Inference mode** to
   *Customer-hosted (your own AWS account)* and fill in
   **Customer inference role ARN**, **Customer inference region**,
   **Primary model** and **Escalation model**. Optional overrides go under
   **Model pins by source type**; a blank tier uses the default for that tier.
4. If any identifier starts with `global.`, the page shows the geography
   acknowledgement and holds saving until you tick it.
5. Choose **Save configuration**. On success the page reports the new mode and
   verification state.

After a save, the **Role policy** section shows the role name, both policies, and a
Terraform snippet. If verification failed, reload the page to see the recorded fault
and what to change, then save again. The page also lists the **Capability probes**
Soroush ran and the **Spend guards in force**.

### CLI

`soroush inference` has three subcommands: `get`, `apply` and `verify`. Each accepts
`--json` to print one machine-readable document. Point the CLI at the Soroush API with
an admin credential:

```sh
export SOROUSH_API_URL="<the Soroush API base URL>"
export SOROUSH_API_KEY="<an admin API key>"
```

`--api` and `--api-key` override the two variables. With no API key configured, the CLI
uses a Cognito ID token from `--credential` or `SOROUSH_DEPLOY_CREDENTIAL`.

```sh
soroush inference get                           # step 1: the External ID and the principal ARN
soroush inference apply --file inference.json   # step 4: replace the configuration
```

With `inference.json`:

```json
{
  "inferenceConfiguration": {
    "mode": "customer_hosted",
    "customerRoleArn": "arn:aws:iam::111122223333:role/soroush-inference-AB12345678",
    "customerRegion": "us-east-1",
    "profiles": {
      "primary": "us.amazon.nova-micro-v1:0",
      "escalation": "us.amazon.nova-2-lite-v1:0"
    },
    "pins": {
      "openapi": { "primary": "us.amazon.nova-micro-v1:0" }
    }
  }
}
```

- `apply` takes the whole body, as above, or the inner object on its own. `-` reads the
  document from stdin.
- `apply` replaces the configuration. In a `customer_hosted` document, an omitted pin
  is a removed pin. Pin keys are `openapi`, `markdown`, `html` and `text`, and each tier
  is optional.
- Leave out `externalId` and `accountId`. Soroush manages both, and refuses a document
  that names either.
- For a `global.` identifier, add
  `"geographyAcknowledgements": [{ "profileId": "<the global. identifier>" }]`, one
  entry per identifier. The acknowledgement is recorded against your credential.
- A failed verification exits `1`, so a pipeline stops: the API answered `409` and the
  mode is unchanged. After fixing the fault, run `apply` again to switch the mode.
  `soroush inference verify` re-checks the stored configuration without switching it.

### Terraform

One apply does all of it:

- the `soroush_inference_configuration` data source reads your External ID, the
  principal ARN, and your Soroush Account id, taking no arguments and needing no role;
- the `modules/inference-role` module creates the role in your account with the `aws`
  provider;
- the `soroush_inference_configuration` resource points Soroush at the role, and the
  apply fails unless verification passes.

```terraform
terraform {
  # The inference-role module needs Terraform 1.9. The provider itself works on 1.5.
  required_version = ">= 1.9"

  required_providers {
    soroush = {
      source  = "DanaAIhq/soroush"
      version = "~> 0.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# SOROUSH_API_KEY (an admin key) and SOROUSH_API_URL come from the environment.
provider "soroush" {}

# Credentials for your own AWS account, where the role is created.
provider "aws" {
  region = local.region
}

locals {
  region             = "us-east-1"
  primary_profile    = "us.amazon.nova-micro-v1:0"
  escalation_profile = "us.amazon.nova-2-lite-v1:0"
  openapi_pin        = local.primary_profile
}

# 1. Read your External ID, Soroush's principal ARN, and your Soroush Account id.
#    No arguments, no role needed.
data "soroush_inference_configuration" "current" {}

# 2. Create the role in your account, named after your Soroush Account id.
module "soroush_inference_role" {
  source = "github.com/DanaAIhq/terraform-provider-soroush//modules/inference-role?ref=v0.2.0"

  external_id             = data.soroush_inference_configuration.current.external_id
  inference_principal_arn = data.soroush_inference_configuration.current.inference_principal_arn
  soroush_account_id      = data.soroush_inference_configuration.current.account_id

  region = local.region
  # Every identifier Soroush may call: both defaults and every pinned identifier.
  profile_ids = distinct([
    local.primary_profile,
    local.escalation_profile,
    local.openapi_pin,
  ])
}

# 3. Point Soroush at the role. The apply fails unless verification passes.
resource "soroush_inference_configuration" "this" {
  mode               = "customer_hosted"
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

output "verification_state" {
  value = soroush_inference_configuration.this.verification_state
}
```

- Set `SOROUSH_API_KEY` to an admin key and `SOROUSH_API_URL` to the Soroush API, and
  give the `aws` provider credentials for your own account.
- `profile_ids` must list both defaults and every pinned identifier.
- `soroush_account_id` names the role. If the data source warns that the API didn't
  report your Account id, set it to the Account id the dashboard shows instead.
- Pin the module's `ref`. The module writes an IAM policy, and an unpinned source can
  change that policy between two applies.
- `terraform plan` checks the role ARN's shape and prefix and the region's syntax,
  requires `role_arn`, `region` and both profiles when `mode` is `customer_hosted`, and
  allows one pin per source type.
- With `mode = "customer_hosted"`, `terraform apply` writes the configuration and then
  requests verification. A verification failure fails the apply with the failure kind
  and what to fix, and records nothing in state; the diagnostic says which mode the
  Account is in. Fix the fault and apply again. With `mode = "soroush_hosted"`, the
  apply writes the configuration and requests no verification.
- Declare the resource once. An Account has one configuration, and there is nothing to
  import: an apply adopts whatever the Account holds.
- The resource and the data source record `external_id` in state in clear text. Use a
  remote backend with encryption at rest and restricted access.

The [resource](../resources/inference_configuration.md) and
[data source](../data-sources/inference_configuration.md) pages document every
attribute.

## Verification

Soroush verifies a configuration before its mode takes effect, every time you save it
with mode `customer_hosted`, even if the same configuration verified before. The steps
run in order and stop at the first failure:

1. **Assume your role with the External ID.** This must succeed.
2. **Assume it again with no External ID.** This must be refused. If it succeeds, your
   trust policy lacks the `sts:ExternalId` condition, and the configuration is refused
   with `external_id_rejected`.
3. **Probe each distinct identifier**, across both defaults and every pin: one
   `Converse` call in your region under your role, retried once if Bedrock throttles
   it. The request is fixed: a three-line synthetic API description, one tool the model
   is forced to call, and a 32-token output cap. The probe passes when the model returns
   that tool call. It never carries your documents.

Until a configuration is verified, the probe is the only model call Soroush makes in
your account: no generation runs there.

**On success**, the verification state becomes `verified` and the mode becomes
`customer_hosted`. The dashboard reports the new mode and state,
`soroush inference apply` prints the configuration and exits `0`, and
`terraform apply` succeeds with `verification_state = "verified"`. Each probe's result,
the model's stop reason, and the input modalities Soroush knows for the model
(`unknown` if it doesn't) are recorded; the last two are informational.

**On failure**, the API answers `409` with an `inferenceFailure`: the failure kind and,
where they apply, the role ARN, the region, the identifier concerned, and the AWS error
class. The mode stays where it was. Soroush stores what you submitted and the outcome,
so the state becomes `failed`, or `unverified` when the probe was throttled, which means
"not judged yet" rather than "wrong". If the Account was `soroush_hosted`, generation
carries on in Soroush's account. If it was already `customer_hosted`, the configuration
that failed is now the stored one, and customer-hosted generation is refused with
`not_verified` until a configuration verifies or you switch back. See
[Troubleshooting](#troubleshooting).

**To verify again**, use **Request verification** on the Inference page,
`soroush inference verify`, or `POST /v1/inference-configuration/verify`; in Terraform,
every create or update with `mode = "customer_hosted"` verifies, and one with
`mode = "soroush_hosted"` doesn't. Verifying never changes the mode; only saving does. It
checks the stored role, region and profiles, so on a `soroush_hosted` Account that kept
a customer configuration it tells you whether switching would work, without switching.
With no customer configuration stored, it answers `409`.

Soroush doesn't re-verify on a schedule. A change you make to the role later is found by
the next generation, which fails with the reason. Request verification after changing
the role.

## What you see in your AWS account

### CloudTrail

| Event | Source | When |
|---|---|---|
| `AssumeRole` | `sts.amazonaws.com` | Once per generation request, before its model calls, and twice per verification: once with the External ID, and once without it, which your trust policy should refuse. The role session name is `soroush-<Account id>`, so each assumption is attributed to your Soroush Account. |
| `Converse` | `bedrock.amazonaws.com` | Once per model call, naming the inference profile: each generation attempt and each probe. The retry of a throttled call is a second call. |

Soroush never caches or reuses credentials, so each generation request makes a fresh
`AssumeRole`. The Bedrock calls are made by your role's session. Soroush holds no
CloudTrail permission in your account and makes no attempt to suppress, obscure, or
aggregate your trail.

Soroush also keeps its own record of every attempt, in both modes, naming the AWS
account, region, inference profile and mode. The dashboard shows it on each draft,
under **Where this draft was produced**.

### Model invocation logging

The CloudTrail events record that a call happened and which profile it used, not what
it carried. Bedrock model invocation logging is a separate setting in your own account,
off unless you turn it on. Turned on, it writes prompt and completion content, which
here means the extracted text of your documents and the model's output, to an S3
bucket or CloudWatch Logs group you control. Soroush neither configures it nor reads
it.

### Cost

- **Model calls** in `customer_hosted` mode are billed to your AWS account at your
  rates. A generation typically makes one to three: a first attempt, plus correction
  attempts when a draft fails validation.
- **The probe** is one call per distinct identifier per verification, with about 60
  tokens of synthetic input and at most 32 output tokens. Verification runs on every
  save with mode `customer_hosted` and on every explicit verification request. A
  successful Terraform create or update with `mode = "customer_hosted"` verifies twice:
  once when it writes and once when it requests verification. One with
  `mode = "soroush_hosted"` doesn't verify.
- **No cost figure in Soroush.** In this mode Soroush records token counts but no cost,
  because the rate is yours. There is no pass-through, metering, or invoice line in
  either direction.
- **Spend guards.** Soroush's per-Account limits on generation requests per hour,
  concurrent requests, and input and output tokens per attempt apply in both modes. The
  Inference page shows them under **Spend guards in force**, and the read returns them
  as `effectiveLimits`. You can see them but not change them.
- **Throttling** counts against your own Bedrock quota. Soroush retries a throttled call
  once against the same profile. If it is still throttled, the generation fails, and
  its attempt records name your account, region and profile. Raise the quota in your
  account.

## Switching back

You can return to `soroush_hosted` at any time, from any verification state including
`failed`. The switch applies immediately, with no verification.

- **Dashboard:** set **Inference mode** to *Soroush-hosted (the default)* and choose
  **Save configuration**.
- **CLI:** `echo '{"inferenceConfiguration":{"mode":"soroush_hosted"}}' | soroush inference apply -`
- **Terraform:** set `mode = "soroush_hosted"` and apply, remove the resource, or run
  `terraform destroy`. None of the three verifies. Setting the mode keeps the resource
  in state, where `verification_state` and `inference_failure` go on describing the
  customer configuration Soroush kept. Removing or destroying the resource writes the
  mode and nothing else. There is no delete, because an Account always has a
  configuration: its absence means `soroush_hosted`.

**Kept:** the External ID, the role ARN, the region, both defaults and every pin, and
the last verification outcome. Your trust policy keeps working, and switching forward
again needs nothing re-entered. It does verify again, as every switch into
`customer_hosted` does.

**Changed:** from the switch on, generation runs in Soroush's account and region, on
Soroush's bill, so your documentation is processed there again. The change is recorded
with who made it. A generation already running finishes in the mode it started in.

~> Switch back before you delete the role. A `customer_hosted` Account whose role is gone fails every generation, and never falls back to Soroush's account, until you switch back or restore the role.

## Troubleshooting

A failure shows up in four places:

- the **Inference** page's fault panel, with what to change in your account (the
  generation page links to it);
- `soroush inference verify`, or a failed `apply`, which prints the failure and exits `1`;
- a failed `terraform apply`, which names the kind and a remedy, and the resource's
  `verification_state` and `inference_failure` attributes, read back on every refresh;
- the API's `409` body, as `inferenceFailure`.

Each names the AWS error class and never the AWS error message, which can quote your
documentation. After fixing the cause, save the configuration again to switch into
`customer_hosted`; if the Account is already `customer_hosted`, requesting verification
is enough.

Invalid input is refused earlier, with a `400` that names each field, before any role is
assumed: a role name without the `soroush-inference-` prefix, a role in Soroush's own
account, a region that isn't a region name, a malformed or refused identifier, a
`global.` identifier without an acknowledgement, or a document naming `externalId` or
`accountId`.

| Kind | What it means | What to fix |
|---|---|---|
| `not_verified` | The Account is `customer_hosted` but its configuration isn't verified, for example after an External ID rotation, a failed or throttled verification, or a generation that found the role unusable. No model was called. | Fix the fault the Inference page records, then request verification. Or switch back. |
| `role_assumption_refused` | `sts:AssumeRole` failed. With `AccessDenied`, STS doesn't say why: the role doesn't exist, its trust policy doesn't admit Soroush's principal, or its `sts:ExternalId` condition names another value, as after a rotation. | Check that the role exists under the ARN you saved, that its trust policy names the inference principal ARN, and that its External ID is the current one. |
| `external_id_rejected` | Soroush could assume the role without an External ID, so the trust policy has no `sts:ExternalId` condition. Soroush refuses the role even though it could assume it. | Add the `StringEquals` condition on `sts:ExternalId` with your Account's External ID. |
| `region_unusable` | `sts:AssumeRole` failed with `RegionDisabledException`: STS isn't active for your account in the region Soroush calls it in, `eu-central-1`. | Activate STS for `eu-central-1` in your account's IAM account settings. |
| `profile_unavailable` | Bedrock rejected the identifier in your region with `ValidationException` or `ResourceNotFoundException`. It doesn't exist or isn't active there, or you named a bare model id that the region serves only through an inference profile. | Check the identifier against the inference profiles your region serves, prefer an inference profile to a bare model id, and check model access in the Bedrock console. |
| `access_denied` | Bedrock returned `AccessDeniedException` to the probe. The permission policy doesn't cover this identifier (usually a missing foundation-model ARN or a pinned identifier left out), or model access isn't enabled for it in your account. | Attach the permission policy Soroush renders for your current configuration, and check model access in the Bedrock console. |
| `capability_unsupported` | The model answered without calling the forced tool. Soroush constrains every draft to a schema through that tool call, so the model can't be used. | Choose a model that supports a forced tool call. |
| `probe_throttled` | Bedrock throttled the probe, retry included. This isn't a verdict: the state stays `unverified`. | Try again shortly. If it recurs, raise your Bedrock quota for the model. |
| `probe_failed` | The probe failed for another reason, including running out of time. | Use the recorded AWS error class as the lead, check that the role and identifier are the ones you meant, and try again. |
| `refused_model_resource` | A stored identifier names a fine-tuned, distilled, custom-imported, provisioned-throughput, or non-Bedrock resource. | Name a Bedrock foundation model or inference profile. |
| `geography_unacknowledged` | A stored `global.` identifier has no acknowledgement for that exact identifier. | Acknowledge it on the dashboard or in a CLI document, or choose a single-geography profile. |

The last two are normally caught at save time as `400` errors. The kinds appear when a
generation meets a stored identifier that fails the same check.

After verification, a generation whose model call fails is reported on the generation
request itself, as `model_throttled`, `profile_unavailable`, or `model_error` naming the
AWS error class. Request verification to re-check the configuration.

## Security notes

- **No fallback to Soroush's account.** If Soroush can't assume your role or call your
  model, the generation fails and says why. The mode is stamped on each generation
  request when it's created, and the only model client built for a `customer_hosted`
  request carries your role's credentials, so a failure can't turn into a call in
  Soroush's account.
- **No training on your data.** Soroush doesn't train, fine-tune, or distil models on
  customer data, in either mode. The permission policy grants no model-customization
  action, and adapted models are refused.
- **Short-lived access only.** Soroush assumes your role once per generation request,
  for a 15-minute session, and never caches or reuses the credentials. It holds no
  long-lived credential for your account. You can delete the role, remove Soroush's
  principal from the trust policy, or narrow the permission policy at any time, and the
  next request fails. Checks, Alert Rules, drafts and everything else that doesn't call
  a model keep working.
- **The External ID.**
  - Soroush generates it from 32 random bytes and shows it as `sor_ext_` followed by 52
    characters. It isn't derived from your Account id, your role ARN, or the time, and
    every Account has a different one. Soroush never accepts one from a request, and
    keeps it across mode changes.
  - It isn't a credential. On its own it lets nobody assume your role: they would also
    have to be Soroush's principal. What it prevents is another Soroush customer who
    learned your role ARN pointing Soroush at your role.
  - Admins of your Account can see it on the Inference page, with
    `soroush inference get`, from `GET /v1/inference-configuration` and its
    `role-policy` route, and through the Terraform data source and resource. So can
    anyone who can read your Terraform state or the role's trust policy. Editors and
    viewers can't. Soroush leaves it out of every error response, log record and audit
    record.
  - **Rotate External ID** on the Inference page, or
    `POST /v1/inference-configuration/rotate-external-id`, replaces it and sets the
    state to `unverified` without changing the mode. Customer-hosted generation is
    refused until your trust policy names the new value and a verification passes. With
    Terraform, the next apply rewrites the trust policy from the data source, but it
    doesn't verify unless the resource itself changes, so request verification
    afterwards.
- **One narrowly scoped principal.** Soroush's inference principal is a single role in
  Soroush's account. Its only permission is `sts:AssumeRole` on roles named
  `soroush-inference-*`, and only Soroush's generation and configuration services can
  use it. The External ID keeps one Account's access separate from another's.
- **Never Soroush's own account.** Soroush refuses a role ARN in its own AWS account, in
  either mode. Its principal could assume a `soroush-inference-*` role there, and the
  configuration would read as customer-hosted while every call ran on Soroush's bill and
  outside your CloudTrail.
- **Admin-only and audited.** Only admins can read or change the configuration, and each
  change records who made it, with the previous and the new mode.
