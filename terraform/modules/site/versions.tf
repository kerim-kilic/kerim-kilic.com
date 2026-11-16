terraform {
  required_version = ">= 1.11" # same floor as the environments that call this module

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1] # CloudFront certificates must live in us-east-1
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
