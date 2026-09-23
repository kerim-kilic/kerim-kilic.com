# kerim-kilic.com

Personal site and articles on cloud architecture. Built with [Hugo](https://gohugo.io/) and hosted on AWS
(private S3 bucket behind CloudFront), with DNS in Cloudflare and infrastructure defined in Terraform.

This is a personal site, published openly as part of a portfolio, not as a template: the names, domains and IDs are
specific to it. You're welcome to read it and reuse the code (see [Licence](#licence)). Typo fixes and corrections are
welcome as issues (pull requests are limited to collaborators). To report a security problem, see
[`SECURITY.md`](SECURITY.md).

## Requirements

- **Hugo** (extended); CI builds with 0.166.0.
- **Terraform** 1.11 or newer and the **AWS CLI**, to manage the infrastructure.
- **Chrome** and **Python with Pillow**, only for the social-card and favicon scripts in `tools/`.

## Local preview

With Hugo installed:

```bash
hugo server -D     # http://localhost:1313, -D includes drafts
```

## Writing

```bash
hugo new content articles/my-article-title.md
```

Set `draft: false` when an article is ready to go public. Things to edit: `hugo.toml` (name, links),
`content/_index.md` (home page), `content/about/`, `data/skills.yaml`, `content/portfolio/`.

## Environments

| | Prod | Dev |
|---|------|-----|
| URL | `kerim-kilic.com` | `dev.kerim-kilic.com` |
| Deployed from | `main` | every other branch (last push wins) |
| Access | public | Cloudflare Access: Google sign-in or a one-time email code, allowlist only |
| Drafts | hidden | visible |
| Search engines | indexed | `noindex` and `robots.txt` disallow |

Pull requests and Dependabot's branches only build. Hugo settings for dev live in `config/dev/hugo.toml`.

## Social preview cards

Links shared on LinkedIn and elsewhere use a 1200x630 card. `static/og/default.png` is the site-wide default; an
article can set its own with `image: "og/<name>.png"` in its front matter. Cards are rendered from
`tools/og/card.html` with headless Chrome:

```bash
tools/og/render.sh static/og/my-article.png "Article title" "One-line summary" "Article"
```

## Favicon

`static/favicon.svg` is the source (a "K" outlined from Space Grotesk Bold). `tools/favicon/build.py` renders
`favicon.ico` and `apple-touch-icon.png` from it (needs Chrome and Pillow).

## Infrastructure (`terraform/`)

```
S3 (private) <- CloudFront (OAC, TLS via ACM, security headers, clean-URL function) <- Cloudflare DNS
GitHub Actions --OIDC--> IAM deploy role --> s3 sync + CloudFront invalidation
```

```
terraform/
  modules/site/   the whole site stack, parameterised by hostname
  modules/private-access/   Cloudflare Access login in front of one hostname
  envs/shared/    account-wide GitHub OIDC provider (apply once)
  envs/dev/       dev.<domain>, behind Cloudflare Access, deploy role trusts any branch
  envs/prod/      <domain> + www redirect, deploy role trusts main only
```

Each folder is its own Terraform state, stored in a private S3 bucket (see below). Dev and prod use the same site module,
so dev is a copy of prod with a login in front. The one difference in traffic path: dev goes through Cloudflare's proxy
(needed for Access), prod goes straight to CloudFront. The deploy roles are separate: a feature branch can never write
to the prod bucket.

How dev is locked down: Cloudflare Access asks people to sign in and only lets allowlisted emails through. Cloudflare
then adds a secret `x-origin-verify` header to each request, and the CloudFront Function returns 403 without it, so the
raw `*.cloudfront.net` address can't be used to skip the login.

### State bucket

State lives in an S3 bucket you create once by hand (it can serve other projects too: each project uses its own key
prefix, and this one uses `kerim-kilic.com/<env>/terraform.tfstate`). Terraform's S3-native locking needs no DynamoDB
table. The bucket should have:

- **Versioning on**, so a bad write or an accidental delete is recoverable.
- **Default encryption** (SSE-S3 or KMS) and **Block Public Access**. State contains secrets, for example the origin
  verification value, so treat the bucket as sensitive.
- A bucket policy that **denies non-TLS requests** (`aws:SecureTransport = false`).
- Optionally a lifecycle rule that expires old noncurrent versions.

The identity you run Terraform with needs `s3:ListBucket` on the bucket and `s3:GetObject`, `s3:PutObject` and
`s3:DeleteObject` on `kerim-kilic.com/*` (locking writes a `.tflock` object next to each state file).

Step-by-step creation instructions and the bucket policy are in `terraform/state-bucket/`. The bucket name is not
committed. Copy `terraform/backend.hcl.example` to `terraform/backend.hcl` (gitignored), set `bucket` and `region`, and
pass it to every `terraform init`.

### First-time setup

You need AWS credentials in your shell and a Cloudflare API token in `CLOUDFLARE_API_TOKEN`. Prod needs
**Zone > DNS > Edit**. Dev also manages Access and rules, so it needs **Account > Access: Apps and Policies > Edit**,
**Account > Access: Organizations, Identity Providers, and Groups > Edit**, **Zone > Transform Rules > Edit** and
**Zone > Config Rules > Edit** (permission names may differ slightly in the dashboard). You also need your Cloudflare
zone ID and account ID.

The AWS identity you run Terraform with needs `ReadOnlyAccess` and the write policy in `terraform/iam/`
(see `terraform/iam/README.md`).

Credentials: create an access key for that IAM user (IAM > Users > Security credentials > Create access key, use case
*CLI*) and store it with `aws configure`. Run it in your own terminal, so the secret isn't echoed anywhere else, and type
the values straight into its prompts (never into a scratch file or chat). Either use the `default` profile, or a named
one (`aws configure --profile kerim-website`, then `export AWS_PROFILE=kerim-website`). The default profile is picked up
by every tool in that terminal, so deleting the key and `~/.aws/credentials` at the end of a session matters even more.

Session workflow: instead of keeping a key around, create one at the start of a working session and delete it at the end
(the policy in `terraform/iam/self-service-policy.json` lets the IAM user do that, in an MFA console session only).

- **Start:** console, signed in as the IAM user with MFA, then *Security credentials* > *Create access key* (CLI). Run
  `aws configure --profile kerim-website` in your own terminal, check with `aws sts get-caller-identity --profile
  kerim-website` (a brand-new key can take up to a minute to work), then `export AWS_PROFILE=kerim-website`.
- **End:** make sure no `terraform apply` is still running (a CloudFront change can take 10+ minutes, and deleting the key
  mid-run leaves a stale state lock). Delete the key in the console, then remove the local copy: `rm ~/.aws/credentials`.

GitHub Actions never uses a key: it assumes a role through OIDC. Other options for local credentials are `aws login`
(short-lived, MFA at sign-in; at the time of writing it fails for some IAM users with MFA, see aws/aws-cli issue 10267),
IAM Identity Center, or a policy that denies everything unless the session used MFA.

Before the first apply, in the Cloudflare dashboard:

- Delete any existing DNS records with the same names, or the apply will fail.
- Enable **Zero Trust** on the account (the free plan is enough for a few people; Cloudflare may ask you to pick a team
  name, and possibly a payment method).
- Check **Rules**: `envs/dev` owns the zone's Transform Rules (modify request header) and Configuration Rules. If you
  already have rules of those two types they would be replaced, so add them to `modules/private-access/main.tf` first.

Optional, for "Sign in with Google": in the Google Cloud console create an OAuth client (type *Web application*) with the
authorised redirect URI `https://<your-team-name>.cloudflareaccess.com/cdn-cgi/access/callback`, set the consent screen
to *In production* (only basic email scopes are requested), and put the client ID and secret in
`envs/dev/terraform.tfvars`. Without them, people get a one-time code by email instead. Terraform creates that
one-time PIN login method itself (a new Cloudflare account doesn't have it switched on), and the Access application
offers only the methods Terraform manages, so Cloudflare's own dashboard sign-in, which only members of your account
can use, never appears on the login page.

```bash
# 0. Once: cp terraform/backend.hcl.example terraform/backend.hcl, and fill it in (see "State bucket")

# 1. Account-wide OIDC provider (skip if the account already has the GitHub one)
cd terraform/envs/shared && terraform init -backend-config=../../backend.hcl && terraform apply

# 2. Dev
cd ../dev
cp terraform.tfvars.example terraform.tfvars      # set cloudflare_zone_id
# also set cloudflare_account_id, allowed_emails (yours, plus friends') and the two GitHub IDs
# (github_owner_id, github_repository_id): GitHub's OIDC subject is repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:...
# and the deploy role trusts that exact pair. Owner: curl -s https://api.github.com/users/<owner> (field "id").
# Repository ID: authenticated API, or the subject in a failed AssumeRoleWithWebIdentity event in CloudTrail.
terraform init -backend-config=../../backend.hcl && terraform plan && terraform apply

# 3. Prod, once dev looks right
cd ../prod
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=../../backend.hcl && terraform plan && terraform apply
```

Then add these in GitHub (Settings > Secrets and variables > Actions), using each environment's `terraform output`.
The values are identifiers, not credentials. The two role ARNs are **secrets** only so that GitHub masks them in the
(public) logs, because an ARN contains the AWS account ID. Everything else is a plain **variable**.

Variables (the *Variables* tab):

| Variable | Value |
|----------|-------|
| `AWS_REGION` | the region you used (default `eu-central-1`) |
| `DEV_S3_BUCKET` | `bucket_name` from `envs/dev` |
| `DEV_CLOUDFRONT_DISTRIBUTION_ID` | `cloudfront_distribution_id` from `envs/dev` |
| `PROD_S3_BUCKET` | `bucket_name` from `envs/prod` |
| `PROD_CLOUDFRONT_DISTRIBUTION_ID` | `cloudfront_distribution_id` from `envs/prod` |

Secrets (the *Secrets* tab):

| Secret | Value |
|--------|-------|
| `DEV_AWS_ROLE_ARN` | `deploy_role_arn` from `envs/dev` |
| `PROD_AWS_ROLE_ARN` | `deploy_role_arn` from `envs/prod` |

Apply Terraform and set the variables and secrets **before** pushing, otherwise the first deploy job fails.

### Sharing dev with someone

Add their email address to `allowed_emails` in `terraform/envs/dev/terraform.tfvars` (this file is gitignored, so
addresses never reach the public repo), run `terraform apply`, and send them `https://dev.<domain>`. They sign in with
Google, or ask for a one-time code sent to that address. To revoke someone, remove their address and apply again.

### Notes

- Terraform runs from your machine, not from GitHub Actions: the credentials it needs (broad AWS access, a Cloudflare
  token that can edit Access and rules) don't belong in a public repo's secrets, and Terraform creates the roles the
  workflow itself uses.
- Terraform changes are checked on every pull request and push (formatting and validation, no credentials) by
  `.github/workflows/terraform-checks.yml`. Nothing is planned or applied in CI.
- Only the OIDC provider is shared between environments, and it lives in `envs/shared` so destroying dev can't break prod.
- The dev apply changes Cloudflare Access and the two rulesets in your zone, none of which prod needs. Prod only
  writes DNS records.

## Go-live checklist

Dev proves the content and the pipeline. It can't prove what visitors get on prod (the real certificate, headers,
caching, the `www` redirect), because dev sits behind Cloudflare and prod doesn't. So test prod right after go-live.

1. Applying prod replaces whatever the domain served before with the new site, which is empty until the first deploy.
   Remove any old DNS records for the apex and `www` first, and do steps 2 to 4 back-to-back so that gap lasts only a
   couple of minutes.
2. `terraform apply` in `envs/prod`, then set the `PROD_*` repository variables and the `PROD_AWS_ROLE_ARN` secret.
3. Merge `dev` into `main`. The workflow deploys prod.
4. Run the smoke test:

   ```bash
   tools/smoke-test.sh https://kerim-kilic.com --www
   ```

   It checks that the pages and 404 behave, that this is the prod build (not dev), that Cloudflare didn't rewrite the
   email link, the HTTPS redirect, the `www` redirect, the security and cache headers, and that the certificate is the
   ACM one served by CloudFront. It exits non-zero if anything fails.
5. By hand: open the site on a real phone, and paste an article URL into LinkedIn's Post Inspector
   (`linkedin.com/post-inspector`) to check the preview card and refresh LinkedIn's cache.
6. In GitHub, make `main` the default branch and require a pull request to change it.
7. In the repository's About box (the gear icon on the repository page), set the **Website** to `https://kerim-kilic.com`.

Roll back a bad content deploy by reverting the merge on `main`; the workflow redeploys the previous version.

## Licence

- The **code and configuration** are MIT licensed: see [`LICENSE`](LICENSE).
- The **writing, photograph, personal data and diagram drawings** are all rights reserved: see
  [`CONTENT-LICENSE.md`](CONTENT-LICENSE.md).
- **Third-party material** (fonts, icons, the AWS Architecture Icons in the diagrams) keeps its own terms:
  see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

## Credits

- Diagrams in `assets/diagrams/` use icons from the [AWS Architecture Icons](https://aws.amazon.com/architecture/icons/)
  (CloudFront, S3, IAM), embedded unmodified and scaled only. AWS, Amazon S3, Amazon CloudFront and AWS Identity and
  Access Management are trademarks of Amazon.com, Inc. or its affiliates. This site is not affiliated with or endorsed
  by AWS.
- Font: Inter under the SIL Open Font License (the favicon "K" is outlined from Space Grotesk, same licence); icons: Bootstrap Icons (MIT). Licence texts and
  attribution are in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
