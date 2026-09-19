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

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to deploy the site."
  type        = string
  default     = "kerim-kilic/kerim-kilic.com"
}
