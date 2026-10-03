# Outputs.
#
# `role_arn` is the one the configuration needs — it feeds the
# `soroush_inference_configuration` resource's `role_arn`. The other four exist so the
# thing this module grants is visible without reading state: a policy nobody can see
# is a policy nobody reviews, which is the failure mode pasted JSON has and the reason
# this ships as a module.

output "role_arn" {
  description = "The role Soroush assumes. Pass this to the soroush_inference_configuration resource's role_arn."
  value       = aws_iam_role.inference.arn
}

output "role_name" {
  description = "soroush-inference-<soroush_account_id>. Soroush's inference principal is scoped to this prefix and may assume nothing outside it."
  value       = aws_iam_role.inference.name
}

output "invocation_resource_arns" {
  description = <<-EOT
    Every ARN the permission policy grants `bedrock:InvokeModel` on, in policy order:
    for each identifier, its inference-profile ARN and then the foundation-model ARN it
    routes to. Two per geography-prefixed identifier, one per bare foundation-model id.

    The same ARNs, in the same order, as the permission policy the Soroush dashboard
    renders for the same region and identifiers.
  EOT
  value       = local.invocation_resource_arns
}

output "permission_policy_json" {
  description = "The inline permission policy as IAM receives it. Readable in a plan, so what is granted is reviewed on every change rather than once when it was pasted."
  value       = jsonencode(local.permission_policy)
}

output "trust_policy_json" {
  description = "The trust policy as IAM receives it: one statement, one principal, sts:AssumeRole, and the sts:ExternalId condition. Not sensitive — see the external_id variable for why."
  value       = jsonencode(local.trust_policy)
}
