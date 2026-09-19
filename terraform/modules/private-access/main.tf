# Puts Cloudflare Access (login) in front of one hostname, and makes Cloudflare stamp every request it
# forwards with a secret header so the origin can refuse anything that didn't come through Cloudflare.

resource "cloudflare_zero_trust_access_identity_provider" "google" {
  count = var.google_client_id != "" ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "Google"
  type       = "google"

  config = {
    client_id     = var.google_client_id
    client_secret = var.google_client_secret
  }
}

resource "cloudflare_zero_trust_access_policy" "allow_list" {
  account_id       = var.cloudflare_account_id
  name             = "${var.hostname}: allowed people"
  decision         = "allow"
  session_duration = var.session_duration

  include = [for email in var.allowed_emails : { email = { email = email } }]
}

# No allowed_idps set: every configured login method is offered (Google, plus the built-in one-time code).
resource "cloudflare_zero_trust_access_application" "site" {
  account_id       = var.cloudflare_account_id
  name             = var.hostname
  domain           = var.hostname
  type             = "self_hosted"
  session_duration = var.session_duration

  policies = [{
    id         = cloudflare_zero_trust_access_policy.allow_list.id
    precedence = 1
  }]

  depends_on = [cloudflare_zero_trust_access_identity_provider.google]
}

# WARNING: a zone has ONE ruleset per phase, and this resource owns it. Any Transform Rule (modify request
# header) you created by hand in the dashboard for this zone would be replaced. Check before applying.
resource "cloudflare_ruleset" "origin_header" {
  zone_id     = var.cloudflare_zone_id
  name        = "Origin verification header"
  description = "Managed by Terraform (${var.hostname})"
  kind        = "zone"
  phase       = "http_request_late_transform"

  rules = [{
    description = "Mark requests for ${var.hostname} as having passed through Cloudflare (and so through Access)"
    action      = "rewrite"
    expression  = "(http.host eq \"${var.hostname}\")"
    enabled     = true

    action_parameters = {
      headers = {
        "x-origin-verify" = {
          operation = "set"
          value     = var.origin_verify_secret
        }
      }
    }
  }]

  # Never start stamping requests before the login is in place.
  depends_on = [cloudflare_zero_trust_access_application.site]
}

# Same warning as above, for the configuration-rules phase. Cloudflare must speak HTTPS to CloudFront and
# check its certificate; a rule scoped to this hostname avoids changing the SSL mode for the whole zone.
resource "cloudflare_ruleset" "origin_tls" {
  zone_id     = var.cloudflare_zone_id
  name        = "Strict TLS to origin"
  description = "Managed by Terraform (${var.hostname})"
  kind        = "zone"
  phase       = "http_config_settings"

  rules = [{
    description = "Full (strict) TLS between Cloudflare and CloudFront for ${var.hostname}"
    action      = "set_config"
    expression  = "(http.host eq \"${var.hostname}\")"
    enabled     = true

    action_parameters = {
      ssl = "strict"
    }
  }]
}
