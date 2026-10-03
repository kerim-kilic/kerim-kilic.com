resource "aws_acm_certificate" "site" {
  provider                  = aws.us_east_1
  domain_name               = var.hostname
  subject_alternative_names = var.www_redirect ? ["www.${var.hostname}"] : []
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Certificate validation records, created in Cloudflare (DNS only).
resource "cloudflare_dns_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => dvo
  }

  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in cloudflare_dns_record.cert_validation : r.name]
}

# Site records. DNS only by default, so traffic goes straight to CloudFront; dev proxies them through
# Cloudflare so Access can sit in front. Cloudflare flattens a CNAME at the apex automatically.
resource "cloudflare_dns_record" "site" {
  for_each = toset(local.aliases)

  zone_id = var.cloudflare_zone_id
  name    = each.key
  type    = "CNAME"
  content = aws_cloudfront_distribution.site.domain_name
  ttl     = 1 # automatic; required when proxied
  proxied = var.dns_proxied
}
