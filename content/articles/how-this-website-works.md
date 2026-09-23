---
title: "How this website works"
date: 2026-09-19
description: "A private S3 bucket behind CloudFront, DNS in Cloudflare, Terraform for the infrastructure and keyless deploys from GitHub Actions: what I built, why, and what doesn't behave as you'd expect."
tags: ["aws", "terraform", "cloudfront", "s3", "github-actions"]
image: "og/how-this-website-works.png"
draft: true
---

This site is about as small as a production system gets: a handful of HTML files, no database, no login. I still wanted to build it the way I would build something at work, for two reasons. The infrastructure is part of what I want to show, and the repository is public, so it has to be something I'm comfortable with people reading.

This article walks through how it fits together, the decisions behind it, and the few places where the platform doesn't behave the way I expected. The [full source](https://github.com/kerim-kilic/kerim-kilic.com) is on GitHub.

## What I wanted

- It should cost next to nothing and need no maintenance: no servers to patch or scale.
- HTTPS on my own domain, with sensible security headers.
- All of it in code, so I can rebuild it from the repository.
- Publishing should be a `git push`, without long-lived AWS keys stored in GitHub.
- Safe to make public: no secrets in the repo, and a deploy role that can't do much damage if someone misused it.

## The request path

The site is generated with [Hugo](https://gohugo.io/): one binary, Markdown in, HTML out, and a build that takes well under a second. The output is served from S3 through CloudFront.

{{< diagram name="request-path" caption="The bucket is private. The only route to a page is through CloudFront, which rewrites the URL, checks its cache and, on a miss, reads from S3 with a signed request. On production, Cloudflare only answers the DNS lookup; it doesn't proxy any traffic." >}}

### Why not just turn on S3 website hosting?

S3 has a static website mode, and it's the obvious first thing to reach for. It has two problems here. The website endpoint only speaks HTTP, so there is no HTTPS on a custom domain. And it needs a public bucket.

Putting CloudFront in front solves both. CloudFront terminates TLS with a certificate for my domain, and the bucket stays private. With origin access control (OAC) CloudFront signs its requests to S3, and the bucket policy allows reads only from this one distribution. S3 Block Public Access is switched on as well, so a mistaken policy change later can't expose the bucket.

## Three things that don't behave as you'd expect

### 1. Clean URLs need a function

Hugo writes `/articles/my-post/index.html` and links to `/articles/my-post/`. CloudFront's default root object only applies to the site root, and with the private S3 origin nothing maps a folder path to the `index.html` inside it, so those requests fail.

A small CloudFront Function running at the viewer-request stage fixes the path before the cache lookup. It also handles the `www` to apex redirect, so I don't need a second distribution or bucket for that:

```javascript
function handler(event) {
  var request = event.request;
  var host = request.headers.host.value;

  if (host.indexOf('www.') === 0) {
    return {
      statusCode: 301,
      statusDescription: 'Moved Permanently',
      headers: { location: { value: 'https://' + host.substring(4) + request.uri } }
    };
  }

  var uri = request.uri;
  if (uri.endsWith('/')) {
    request.uri += 'index.html';
  } else if (uri.indexOf('.', uri.lastIndexOf('/')) === -1) {
    request.uri += '/index.html';
  }
  return request;
}
```

### 2. A missing page comes back as 403, not 404

Because the bucket is private and CloudFront has no permission to list it, S3 answers a request for a key that doesn't exist with `403 Forbidden`. It won't reveal whether the object exists. Visitors would get a bare error page. The distribution maps both 403 and 404 to my own `/404.html`, returned with a 404 status.

### 3. The certificate lives in us-east-1, and DNS is somewhere else

CloudFront only accepts ACM certificates from us-east-1, so Terraform uses a second, aliased AWS provider just for the certificate. My DNS is in Cloudflare, so the validation records are created by the Cloudflare provider and the certificate waits for them.

The records that point the domain at CloudFront are set to DNS only, so traffic goes straight to CloudFront instead of through Cloudflare's proxy. Cloudflare flattens the CNAME at the apex, so both `kerim-kilic.com` and `www` work.

## The deploy path: no AWS keys in GitHub

{{< diagram name="deploy-path" caption="A push to `main` starts the workflow. It never holds an AWS access key: it exchanges a short-lived OIDC token for temporary credentials, and only this repository's `main` branch is allowed to do that." >}}

The workflow builds the site on every push and pull request. Pushes to `main` deploy to production; the diagram shows that path. Instead of an IAM user whose access keys sit in GitHub secrets, it uses OpenID Connect. GitHub issues each run a signed token describing where the run came from, AWS STS checks that token against the role's trust policy, and hands back credentials that expire (after an hour by default).

The part that matters is the role's trust policy:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = [for ref in var.deploy_ref_patterns : "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo}@${var.github_repository_id}:ref:${ref}"]
}
```

For production, `deploy_ref_patterns` is `["refs/heads/main"]`, so only the `main` branch of this repository can assume the role. The role's permissions are small too: list the bucket, put and delete objects in it, and create an invalidation on this one distribution. Even if the role were misused, the worst outcome is a defaced website, not a compromised AWS account.

Three things I learnt setting this up:

- **GitHub now identifies the repository by numeric IDs.** My first deploy failed with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, and the trust policy looked right. CloudTrail showed why: the token's subject was `repo:<owner>@<owner id>/<repo>@<repo id>:ref:refs/heads/dev`, not the older `repo:<owner>/<repo>:ref:...` I had written. Pinning the immutable IDs is the better fix than loosening the pattern with wildcards, because it stops someone who later recreates an account or repository with the same name from inheriting the trust. CloudTrail records the failed attempt, including the subject GitHub sent, so it's the quickest place to look.
- **The repository name is baked into the trust policy.** I settled the name before the first `terraform apply`; renaming it afterwards would break deployments until the policy is updated.
- **An AWS account can only have one GitHub OIDC provider.** It lives in its own small Terraform stack, shared by every environment, so tearing down one environment can't break another.

### Caching

Left alone, S3 objects come back without a `Cache-Control` header and browsers guess how long to keep them, which means stale pages after a deploy. The workflow sets it explicitly, in three groups:

- **Fingerprinted assets** (the CSS and the processed images have a content hash in the filename) are cached for a year and marked `immutable`.
- **Files whose names never change**, such as the fonts and the social preview images, are cached for a day.
- **Everything else**, mostly HTML, is revalidated by browsers on every visit, while CloudFront may keep it for up to a day. Every deploy invalidates `/*`, so new content shows up straight away. The site is small enough that invalidating everything is simpler than anything cleverer.

## A dev site before production

I didn't want the first version of an article to go live untested, so there are two environments built from the same Terraform module: production, and a dev copy at `dev.kerim-kilic.com`.

- **Branches decide the target.** `main` deploys to production. Any other branch deploys to dev, and pull requests only build.
- **Separate roles.** The production role trusts `main` only (the pattern above), and the dev role trusts any branch but can only write the dev bucket, so a feature branch can never touch the live site.
- **Dev is private.** It sits behind Cloudflare Access: friends sign in with Google or a one-time code sent to their email, and only addresses on an allowlist get through. I considered an IP allowlist, but a home IP changes without warning and it can't cover friends on other networks.
- **The login methods are listed explicitly.** A new Cloudflare account doesn't have the one-time code login switched on, so Terraform creates it. Left unrestricted, the login page also offers "Cloudflare" sign-in, which only members of my Cloudflare account can use, and my first tester hit exactly that dead end. The Access application now names the methods it accepts.
- **The back door is closed.** Cloudflare adds a secret header to every request it forwards, and the CloudFront Function refuses anything without it. Without that check, anyone who found the raw `cloudfront.net` address could skip the login.
- **Dev shows drafts, marked `noindex`.** It builds with drafts visible and tells search engines to stay away, so I can review an article there before it goes public.

Because the two environments share a module, dev is a copy of production with a login in front. The one difference is the traffic path: dev goes through Cloudflare's proxy so Access can work, while production goes straight to CloudFront. Anything that works on dev should work on production, apart from that extra hop. To cover the gap, a small script (`tools/smoke-test.sh`) checks the live production site right after go-live: pages, the 404, the redirects, the security and cache headers, and that the certificate is the one CloudFront serves.

## How the Terraform is laid out

The site itself is one module, `modules/site`, that takes a hostname and produces everything below. Two small root folders, one per environment, use it, and a third holds the one account-wide resource:

| Path | What it defines |
|------|-----------------|
| `modules/site/s3.tf` | The private bucket, Block Public Access and the bucket policy that trusts CloudFront |
| `modules/site/cloudfront.tf` | The distribution, origin access control, the function, and the managed cache and security-header policies |
| `modules/site/dns.tf` | The ACM certificate, its validation records and the site records in Cloudflare |
| `modules/site/github_oidc.tf` | The deploy role and its permissions |
| `modules/site/function.js.tftpl` | The CloudFront Function shown above, as a template |
| `modules/private-access` | The Cloudflare Access login and two zone rules that keep dev private (dev only) |
| `envs/shared` | The account-wide GitHub OIDC provider |
| `envs/dev`, `envs/prod` | The two environments, each with its own state |

State is stored in a private, versioned S3 bucket, with one key per environment. Recent Terraform versions can lock state with a lock file in the same bucket, so no DynamoDB table is needed.

## What I would change next

- Run Terraform in CI, not only the checks. Pull requests already get format and validation checks, which need no credentials. But I still run `terraform plan` and `apply` from my laptop, because the credentials they need are too powerful to hand to a public repository's workflows. The next step is plans on pull requests and applies on merge, using a separate, narrowly scoped role.
- Add a Content-Security-Policy. The managed security-headers policy covers HSTS, content-type sniffing, framing and referrer policy, but not CSP. The site is static and self-hosted, fonts included, so a strict CSP should be easy to add.
- Pin the GitHub Actions to commit SHAs. They follow major-version tags and Dependabot proposes updates, but a maintainer can move a tag and nobody can move a commit SHA.
- Logging. There are no access logs or alerts yet.

That's all of it. If you spot a mistake, or you'd have done something differently, I'd like to hear about it. You can reach me on [LinkedIn](https://www.linkedin.com/in/kerim-kilic/) or by {{< email "email" >}}.
