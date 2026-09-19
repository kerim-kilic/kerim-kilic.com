# Account-wide resources used by every environment. Apply this once, before dev and prod.
# Skip this stack if the AWS account already has the GitHub Actions OIDC provider
# (there can only be one per account).
terraform {
  required_version = ">= 1.11" # S3-native state locking (use_lockfile)

  # Bucket and region are not committed; pass them with: terraform init -backend-config=../../backend.hcl
  backend "s3" {
    key          = "kerim-kilic.com/shared/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "aws_region" {
  description = "Region for the provider (IAM is global, but the provider needs one)."
  type        = string
  default     = "eu-central-1"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "website"
      ManagedBy = "terraform"
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
