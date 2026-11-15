terraform {
  required_version = ">= 1.11" # same floor as the environments that call this module

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
