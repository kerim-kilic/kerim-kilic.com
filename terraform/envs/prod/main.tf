# Prod: the public site, deployed only from the main branch.
module "site" {
  source = "../../modules/site"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  hostname             = var.domain_name
  www_redirect         = true
  cloudflare_zone_id   = var.cloudflare_zone_id
  github_repository    = var.github_repository
  github_owner_id      = var.github_owner_id
  github_repository_id = var.github_repository_id
  deploy_ref_patterns  = ["refs/heads/main"]
}
