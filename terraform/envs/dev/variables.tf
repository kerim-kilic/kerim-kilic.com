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

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (dashboard > any domain > Overview > right-hand column). Zero Trust must be enabled."
  type        = string
}

variable "allowed_emails" {
  description = "Email addresses allowed to view dev. Keep them in terraform.tfvars, not in git."
  type        = list(string)
}

variable "google_client_id" {
  description = "Google OAuth client ID for 'Sign in with Google'. Leave empty to offer only the one-time email code."
  type        = string
  default     = ""
}

variable "google_client_secret" {
  description = "Google OAuth client secret."
  type        = string
  default     = ""
  sensitive   = true
}
