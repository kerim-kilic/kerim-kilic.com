locals {
  bucket_name = "${replace(var.hostname, ".", "-")}-site"
  aliases     = var.www_redirect ? [var.hostname, "www.${var.hostname}"] : [var.hostname]
}
