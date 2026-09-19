output "url" {
  value = module.site.url
}

output "bucket_name" {
  description = "GitHub variable <ENV>_S3_BUCKET."
  value       = module.site.bucket_name
}

output "cloudfront_distribution_id" {
  description = "GitHub variable <ENV>_CLOUDFRONT_DISTRIBUTION_ID."
  value       = module.site.cloudfront_distribution_id
}

output "cloudfront_domain_name" {
  value = module.site.cloudfront_domain_name
}

output "deploy_role_arn" {
  description = "GitHub variable <ENV>_AWS_ROLE_ARN."
  value       = module.site.deploy_role_arn
}
