---
title: "This website: static hosting on AWS"
description: "A private S3 bucket behind CloudFront, defined in Terraform and deployed from GitHub Actions without stored credentials."
stack: ["AWS S3", "CloudFront", "ACM", "Terraform", "GitHub Actions (OIDC)", "Cloudflare DNS", "Cloudflare Access", "Hugo"]
weight: 1
---

## Overview

This site is plain HTML built with Hugo and served from a private S3 bucket through CloudFront. The infrastructure is in [`terraform/`](https://github.com/kerim-kilic/kerim-kilic.com/tree/main/terraform), in the same repository as the site.

## How it's set up

- The S3 bucket blocks all public access. Only this CloudFront distribution can read it, through origin access control.
- The certificate comes from ACM and is validated through DNS records that Terraform creates in Cloudflare.
- A CloudFront Function handles clean URLs and redirects `www` to the bare domain, so there's no server to run.
- Security headers come from a CloudFront response headers policy.
- GitHub Actions deploys by assuming a narrowly scoped IAM role through OIDC. No access keys are stored anywhere.
- The dev site is a second copy of the same stack behind Cloudflare Access (Google sign-in or a one-time email code, allowlist only). Cloudflare adds a secret header that CloudFront checks, so nobody can go around the login through the raw `cloudfront.net` address.

## Why static

A static site costs almost nothing, loads quickly and has nothing to patch. The downside is that anything dynamic, like a form or search, needs a separate service, and I don't need either here. Production doesn't sit behind Cloudflare the way dev does, so I run a smoke test against the live site after each go-live to catch any difference.
