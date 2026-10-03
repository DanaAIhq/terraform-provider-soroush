# Terraform and provider constraints for the inference role module.

terraform {
  # 1.9, not the 1.5 the Soroush provider supports — and the difference is deliberate
  # rather than incidental.
  #
  # `variable "profile_ids"` refuses a malformed identifier by reading the geography
  # list and the separator out of `inference-role-arns.json` (see main.tf's `locals`),
  # and a `variable` validation condition could not refer to a `local` before
  # Terraform 1.9. The only way to keep the floor at 1.5 would be to type the
  # geography list into the condition — which is exactly the hand-maintenance the file
  # exists to prevent: a geography Soroush adds would then be refused by a validator
  # nobody remembered to update, and the refusal would read like a bug in Soroush.
  #
  # This is a floor on the MODULE, not on the provider. `soroush_inference_configuration`
  # and its data source still work on 1.5; a configuration carries this floor only
  # because it calls this module.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Deliberately wide. The module uses `aws_iam_role`, `aws_iam_role_policy`, and
      # `aws_caller_identity`, all of which have been stable in shape since v4, and a
      # narrow constraint in a module is a constraint on the whole configuration that
      # consumes it. The policy documents are built with `jsonencode` rather than
      # `aws_iam_policy_document` for the same reason: one less provider behaviour
      # between inference-role-arns.json and the bytes IAM receives.
      version = ">= 5.0"
    }
  }
}
