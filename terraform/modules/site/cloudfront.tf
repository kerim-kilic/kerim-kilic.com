data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

# Security headers on every response. The CSP fits a static site with no scripts: styles, images and fonts come from
# the site itself; 'unsafe-inline' for styles covers the inline style attributes of the code highlighting and the SVG
# diagrams. HSTS covers subdomains (www and dev are HTTPS-only) but is deliberately not submitted for preload.
resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${local.bucket_name}-security-headers"
  comment = "Security headers for ${var.hostname}"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    content_security_policy {
      content_security_policy = "default-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
      override                = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), interest-cohort=()"
      override = true
    }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${local.bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "rewrite" {
  name    = "${local.bucket_name}-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code = templatefile("${path.module}/function.js.tftpl", {
    origin_verify_secret = var.origin_verify_secret
    www_redirect         = var.www_redirect
  })
}

# Accepted Trivy findings (sitting C of the 2026-11-15 security review):
# - AWS-0010 access logging: off on purpose; the privacy page states that no access logs are kept.
# - AWS-0011 WAF: a static site with no forms or back end; a web ACL would cost money and protect nothing.
#trivy:ignore:AWS-0010
#trivy:ignore:AWS-0011
resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  price_class         = "PriceClass_100" # North America + Europe; cheapest
  default_root_object = "index.html"
  aliases             = local.aliases

  origin {
    origin_id                = "s3"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite.arn
    }
  }

  # A missing object comes back from a private bucket as 403, so handle both.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # Same guard as the bucket: remove it before a deliberate teardown.
  lifecycle {
    prevent_destroy = true
  }
}
