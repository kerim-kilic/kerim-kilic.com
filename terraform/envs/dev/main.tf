# Dev: dev.<domain>, behind Cloudflare Access (Google sign-in or a one-time email code, allowlist only),
# deployed from every branch except main.
locals {
  hostname = "dev.${var.domain_name}"
}

# Shared secret: Cloudflare adds it to every request it forwards, CloudFront refuses requests without it.
# That closes the raw *.cloudfront.net address, which would otherwise skip the login.
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

module "access" {
  source = "../../modules/private-access"

  cloudflare_account_id = var.cloudflare_account_id
  cloudflare_zone_id    = var.cloudflare_zone_id
  hostname              = local.hostname
  allowed_emails        = var.allowed_emails
  google_client_id      = var.google_client_id
  google_client_secret  = var.google_client_secret
  origin_verify_secret  = random_password.origin_verify.result
}

module "site" {
  source = "../../modules/site"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  hostname             = local.hostname
  www_redirect         = false
  dns_proxied          = true
  origin_verify_secret = random_password.origin_verify.result
  cloudflare_zone_id   = var.cloudflare_zone_id
  github_repository    = var.github_repository
  github_owner_id      = var.github_owner_id
  github_repository_id = var.github_repository_id
  deploy_ref_patterns  = ["refs/heads/*"]

  # The login must exist before the site becomes reachable.
  depends_on = [module.access]
}
