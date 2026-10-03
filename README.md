# Soroush Terraform provider

This repository publishes the Soroush Terraform provider: its signed releases, the
documentation the Terraform Registry shows for it, and the Terraform modules that go with it.
Everything here is generated at each release. The provider's source code is not published
here.

## Using the provider

```terraform
terraform {
  required_providers {
    soroush = {
      source  = "DanaAIhq/soroush"
      version = "~> 0.1"
    }
  }
}
```

The documentation is on the Terraform Registry, at
https://registry.terraform.io/providers/DanaAIhq/soroush/latest/docs. The same pages are in
[`docs/`](docs/index.md) at each release tag.

## Modules

[`modules/inference-role`](modules/inference-role/README.md) creates the IAM role in your own
AWS account that Soroush assumes for customer-managed inference. Use it as a Git source pinned
to a release:

```terraform
module "soroush_inference_role" {
  source = "github.com/DanaAIhq/terraform-provider-soroush//modules/inference-role?ref=v0.2.0"

  # Inputs: see the module's README.
}
```

## Releases

Each release is a tag here and a GitHub Release on that tag: one zip per platform, a
`SHA256SUMS` file, its detached signature, and the Registry manifest. `terraform init` checks
the signature when it installs the provider from the Registry.
