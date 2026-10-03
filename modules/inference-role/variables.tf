# Inputs.
#
# Five of these are the module's documented surface — `external_id`,
# `inference_principal_arn`, `soroush_account_id`, `region`, `profile_ids`. The first
# three are read from `data "soroush_inference_configuration"`; the last two are the
# region and the union of the identifiers passed to the `soroush_inference_configuration`
# resource, and they must agree with it or the policy will not cover what the platform
# invokes.
#
# `customer_account_id` is a sixth, optional, and normally left alone. See its own
# comment for why it exists at all.

variable "external_id" {
  type        = string
  description = <<-EOT
    The `sts:ExternalId` the trust policy conditions on. Read it from
    `data.soroush_inference_configuration.<name>.external_id` — it is minted by Soroush
    and derived from nothing, which is what makes it readable before this role exists.

    Not marked `sensitive`, matching the provider's own decision on the same value: it
    authenticates nothing on its own (an attacker would also have to *be* Soroush's
    inference principal), it exists to be read and pasted into a trust policy, and
    marking it sensitive would redact it from the plan — which fights the whole reason
    this policy ships as a module. Note that a Terraform state file holds it in clear
    text; use a remote backend with encryption at rest and restricted read access.
  EOT

  validation {
    condition     = length(trimspace(var.external_id)) > 0
    error_message = "external_id must not be empty or blank. Read it from the soroush_inference_configuration data source; an empty condition value would make the trust policy admit the principal unconditionally."
  }

  validation {
    condition     = var.external_id == trimspace(var.external_id)
    error_message = "external_id must not have leading or trailing whitespace: STS compares the condition value byte for byte, so a padded copy-paste produces a role that can never be assumed."
  }
}

variable "inference_principal_arn" {
  type        = string
  description = <<-EOT
    The **only** principal the trust policy admits. Read it from
    `data.soroush_inference_configuration.<name>.inference_principal_arn` rather than
    copying it out of documentation, so it cannot go stale in your configuration.

    It is a platform fact, identical for every Soroush Account:
    `arn:aws:iam::<soroush-deployment-account>:role/soroush-inference-principal`.
  EOT

  validation {
    # The same grammar Soroush's own validator uses for a role ARN, so a value this
    # module accepts is a value the platform would accept.
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/[\\w+=,.@/-]+$", var.inference_principal_arn))
    error_message = "inference_principal_arn must be an IAM role ARN of the form arn:aws:iam::<12 digits>:role/<name>."
  }

  validation {
    # A wildcard here would widen the trust policy from one principal to many, which
    # is the single most consequential mistake available in this module. The ARN
    # pattern above already excludes `*` in the account field; this refuses it
    # anywhere, and says why.
    condition     = !strcontains(var.inference_principal_arn, "*")
    error_message = "inference_principal_arn must name exactly one principal. A wildcard would let any role matching the pattern assume this role, which is the invariant this module exists to hold."
  }
}

variable "soroush_account_id" {
  type        = string
  description = <<-EOT
    Your Soroush Account id — **not** an AWS account id. The role must be named
    `soroush-inference-<soroush_account_id>`, because Soroush's inference principal is
    scoped to `arn:aws:iam::*:role/soroush-inference-*` and may assume nothing else.

    Read it from `data.soroush_inference_configuration.<name>.account_id`. If the data
    source warns that the API did not report it, pass your Account id explicitly
    instead; it is on the dashboard and on every other Soroush resource.
  EOT

  validation {
    condition     = length(trimspace(var.soroush_account_id)) > 0
    error_message = "soroush_account_id must not be empty or blank: the role name is soroush-inference-<soroush_account_id> and a blank one would produce a trailing-hyphen name the inference principal is not scoped to."
  }

  validation {
    # IAM's own role-name character class. A value outside it fails at apply with an
    # AWS validation error that names a regex rather than a variable.
    condition     = can(regex("^[\\w+=,.@-]+$", var.soroush_account_id))
    error_message = "soroush_account_id must contain only the characters IAM admits in a role name: letters, digits, and _+=,.@-"
  }

  validation {
    # IAM caps a role name at 64 characters, and the prefix spends 18 of them.
    condition     = length("soroush-inference-${var.soroush_account_id}") <= 64
    error_message = "soroush-inference-<soroush_account_id> must be at most 64 characters, the IAM limit on a role name."
  }
}

variable "region" {
  type        = string
  description = <<-EOT
    The AWS region in **your** account that inference runs in. This must be the same
    value passed to the `soroush_inference_configuration` resource's `region`: it is
    the region field of every inference-profile ARN in the permission policy, so a
    mismatch produces a policy that deploys clean and then denies at invocation.

    You choose the geography here, and Soroush does not override it. Enabling
    customer-managed inference moves processing of your documents into this region, in
    your account, on your bill.
  EOT

  validation {
    # Mirrors Soroush's own region check: syntax only. Whether the region *serves* a
    # configured profile is a question for Soroush's capability probe, and no regex can
    # answer it; a checked-in list of regions would start refusing regions the day AWS
    # adds one. This is a typo guard, not the authority — the authority is the platform
    # validator behind `PUT /v1/inference-configuration`.
    condition     = can(regex("^[a-z]{2}-[a-z]+(-[a-z]+)*-[0-9]+$", var.region))
    error_message = "region must be a syntactically valid AWS region, such as us-east-1, eu-central-1, or ap-southeast-3."
  }

  validation {
    condition     = !strcontains(var.region, "*")
    error_message = "region must be one exact region. The only wildcard any ARN in the rendered policy may carry is the region field of a foundation-model ARN, and this module derives that one from inference-role-arns.json."
  }
}

variable "profile_ids" {
  type        = list(string)
  description = <<-EOT
    Every Bedrock inference profile identifier Soroush may invoke on your behalf: the
    resource's `primary_profile` and `escalation_profile`, plus every identifier named
    in a `model_pin`. Pass the union — an identifier missing here is an
    `AccessDeniedException` on the generation that reaches for it.

    Each identifier contributes **two** ARNs to the policy, not one: invoking a
    cross-region inference profile authorizes against the inference-profile ARN *and*
    the underlying foundation-model ARN in whichever region the profile routes to. A
    bare, provider-prefixed foundation-model id (no geography prefix) contributes one.

    Order is preserved and duplicates are folded, so passing the same identifier as
    both a selection and a pin is harmless.
  EOT

  validation {
    condition     = length(var.profile_ids) > 0
    error_message = "profile_ids must name at least one identifier. An IAM statement with an empty Resource list is a silently useless grant: it deploys clean and denies everything."
  }

  # The three malformed cases, taken from `classification.malformedWhen` in
  # inference-role-arns.json rather than from its `refusedIdentifiers` array. The
  # array is a list of examples; the rule is what has to be implemented, or a
  # malformed identifier nobody thought of would sail through.
  validation {
    condition     = alltrue([for id in var.profile_ids : id != ""])
    error_message = "profile_ids must not contain an empty identifier."
  }

  validation {
    condition     = alltrue([for id in var.profile_ids : id == trimspace(id)])
    error_message = "profile_ids must not contain an identifier with leading or trailing whitespace: it is not the string Bedrock would be handed, and the padded copy is what would end up in the ARN."
  }

  validation {
    # "the first segment is a known geography and the remainder is empty" — a bare
    # `eu`, or a dangling `eu.`. Membership is tested against the file's closed
    # `geographies` list, which is also why this module's Terraform floor is 1.9.
    #
    # An identifier whose first segment is *not* a geography is accepted, because the
    # file says `unknownFirstSegmentIsProvider`: `amazon.nova-micro-v1:0` is a bare
    # foundation-model id and legitimate. Refusing every separator-less identifier
    # would be stricter than the platform, which is its own kind of wrong.
    condition = alltrue([
      for id in var.profile_ids : !(
        contains(local.geographies, split(local.geography_separator, id)[0]) &&
        substr(
          id,
          min(length(split(local.geography_separator, id)[0]) + length(local.geography_separator), length(id)),
          -1
        ) == ""
      )
    ])
    error_message = "profile_ids must not contain a bare or dangling geography prefix such as \"eu\" or \"eu.\": a geography prefix names where a model runs, and on its own it names no model. Write the full identifier, for example eu.amazon.nova-micro-v1:0."
  }
}

variable "customer_account_id" {
  type    = string
  default = null

  description = <<-EOT
    Your own AWS account id — the account this role is created in, and the account
    field of every inference-profile ARN in the permission policy.

    **Normally leave this unset.** The module reads it from `aws_caller_identity`,
    which is the same account the `aws` provider is already pointed at, so setting it
    can only disagree with reality.

    It exists because reading the caller identity is a live STS call, which makes it
    impossible to render this module's plan without a credential. Setting it lets the
    plan be rendered offline, for example in a CI job with no AWS account involved, to
    review the exact ARNs the policy will grant. When it is set the
    `aws_caller_identity` data source is not read at all.
  EOT

  validation {
    condition     = var.customer_account_id == null || can(regex("^[0-9]{12}$", var.customer_account_id))
    error_message = "customer_account_id must be a 12-digit AWS account id, or null to read it from the caller identity."
  }
}
