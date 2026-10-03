variable "hostname" {
  description = "Hostname the site is served from, e.g. kerim-kilic.com or dev.kerim-kilic.com."
  type        = string
}

variable "www_redirect" {
  description = "Also serve www.<hostname> and redirect it to <hostname>. Only makes sense for an apex domain."
  type        = bool
  default     = false
}

variable "dns_proxied" {
  description = "Proxy the site's DNS record through Cloudflare (orange cloud). Needed when Cloudflare Access sits in front of the site."
  type        = bool
  default     = false
}

variable "origin_verify_secret" {
  description = "If set, CloudFront rejects any request that lacks this value in the x-origin-verify header. Closes the raw cloudfront.net address when Cloudflare fronts the site."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID that holds the DNS records for the hostname."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may deploy to this environment."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric ID of the GitHub account that owns the repository. GitHub puts it in the OIDC subject claim (repo:<owner>@<owner_id>/<repo>@<repo_id>:...), which pins the trust to this exact account, not just a name that could be recreated."
  type        = string
}

variable "github_repository_id" {
  description = "Numeric ID of the GitHub repository (see github_owner_id)."
  type        = string
}

variable "deploy_ref_patterns" {
  description = "Git refs allowed to assume the deploy role, e.g. [\"refs/heads/main\"] or [\"refs/heads/*\"]."
  type        = list(string)
}
