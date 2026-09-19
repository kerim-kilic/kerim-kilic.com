variable "domain_name" {
  description = "Apex domain of the site."
  type        = string
  default     = "kerim-kilic.com"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the domain (Cloudflare dashboard > domain > Overview)."
  type        = string
}

variable "aws_region" {
  description = "Region for the S3 bucket. CloudFront and the certificate are global / us-east-1 regardless."
  type        = string
  default     = "eu-central-1"
}

variable "github_owner_id" {
  description = "Numeric ID of the GitHub account that owns the repository (GitHub's OIDC subject includes it). For a public account: curl -s https://api.github.com/users/<owner> and read the id."
  type        = string
}

variable "github_repository_id" {
  description = "Numeric ID of the GitHub repository. Private repos need an authenticated API call; alternatively read it from the OIDC subject in a failed AssumeRoleWithWebIdentity event in CloudTrail."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to deploy the site."
  type        = string
  default     = "kerim-kilic/kerim-kilic.com"
}
