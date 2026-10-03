output "hostname" {
  description = "Hostname the site is served from."
  value       = var.hostname
}

output "url" {
  description = "Public URL of the site."
  value       = "https://${var.hostname}"
}

output "bucket_name" {
  description = "S3 bucket holding the site."
  value       = aws_s3_bucket.site.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain_name" {
  description = "Default CloudFront hostname."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "deploy_role_arn" {
  description = "IAM role GitHub Actions assumes to deploy."
  value       = aws_iam_role.deploy.arn
}
