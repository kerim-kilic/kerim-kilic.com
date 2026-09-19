# Prod: the public site, deployed only from the main branch.
module "site" {
  source = "../../modules/site"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  hostname            = var.domain_name
  www_redirect        = true
  cloudflare_zone_id  = var.cloudflare_zone_id
  github_repository   = var.github_repository
  deploy_ref_patterns = ["refs/heads/main"]
}
