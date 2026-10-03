terraform {
  required_version = ">= 1.11" # S3-native state locking (use_lockfile)

  # Bucket and region are not committed; pass them with: terraform init -backend-config=../../backend.hcl
  backend "s3" {
    key          = "kerim-kilic.com/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "website"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront only accepts ACM certificates from us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "website"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# Authenticates with the CLOUDFLARE_API_TOKEN environment variable
# (token needs Zone > DNS > Edit on the zone).
provider "cloudflare" {}
