variable "cloudflare_account_id" {
  description = "Cloudflare account ID (Zero Trust must be enabled on the account)."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID that holds the hostname."
  type        = string
}

variable "hostname" {
  description = "Hostname to protect, e.g. dev.kerim-kilic.com."
  type        = string
}

variable "allowed_emails" {
  description = "Email addresses allowed in. They sign in with Google or a one-time code sent to that address."
  type        = list(string)

  validation {
    condition     = length(var.allowed_emails) > 0
    error_message = "Add at least one email address, otherwise nobody can reach the site."
  }
}

variable "google_client_id" {
  description = "Google OAuth client ID. Leave empty to offer the one-time email code only."
  type        = string
  default     = ""
}

variable "google_client_secret" {
  description = "Google OAuth client secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "origin_verify_secret" {
  description = "Value of the x-origin-verify header Cloudflare adds to every request it forwards to the origin."
  type        = string
  sensitive   = true
}

variable "session_duration" {
  description = "How long a login lasts."
  type        = string
  default     = "24h"
}
