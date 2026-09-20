# Troubleshooting

Symptoms seen while building this setup, with the cause and the fix. Commands assume the AWS CLI is configured for the
account.

## Deploy workflow (GitHub Actions)

| Symptom | Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` at "Configure AWS credentials" | The role's trust policy doesn't match the token's subject. GitHub's subject now includes immutable numeric IDs: `repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:<ref>` | Read the subject GitHub actually sent (below) and pin the IDs in the trust policy |
| The same error, and the subject matches | A wrong role ARN in the `*_AWS_ROLE_ARN` variable, or a role that doesn't exist (AWS returns the same message) | Compare the variable with `terraform output deploy_role_arn` |
| "Credentials could not be loaded", or an empty role | A repository variable is missing or misspelled (`DEV_`/`PROD_` prefix) | Check Settings, Secrets and variables, Actions, Variables |
| Deploy is green but the site shows the old content | The CloudFront invalidation hasn't finished, or the browser cached the page | Wait a minute and hard-refresh; check `aws cloudfront list-invalidations` |
| The whole workflow is rejected as invalid YAML | An unquoted step name containing `: ` | Quote the step name |

**See the exact subject GitHub sent** (works even though the request was refused): CloudTrail records the failed attempt in
the region the runner called.

```bash
aws cloudtrail lookup-events --region <region> \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 5 --query 'Events[].CloudTrailEvent' --output json
```

Read `userIdentity.userName`. `requestParameters` is empty for these events, but `resources` names the role that was
requested. Events can take a few minutes to appear.

## Dev site (Cloudflare Access in front of CloudFront)

| Symptom | Cause | Fix |
|---|---|---|
| Works in a private window, not in the normal browser | Stale cookies or a cached failed lookup in that browser | Clear site data for the dev hostname, or use private windows |
| The login page never sends a code | The email isn't exactly on the allowlist, or the code went to spam | Check `allowed_emails` (exact address, no typos); wait a minute; check spam |
| The login page offers only "Cloudflare", or a guest sees "Cloudflare sign-in is restricted to members of the account" | The one-time PIN login method doesn't exist in the Cloudflare account, so the only method left is the sign-in for account members | Apply `envs/dev`: it creates the one-time PIN method and limits the application to the methods Terraform manages |
| "Too many redirects" after signing in | Cloudflare is talking HTTP to CloudFront (SSL mode Flexible) | Check the configuration rule sets Full (strict) for the dev hostname |
| Cloudflare error 525 or 526 | TLS between Cloudflare and CloudFront failed | Confirm the ACM certificate covers the hostname and is attached to the distribution |
| Plain 403 after signing in | The secret header isn't being added | Check the request-header transform rule exists and matches the dev hostname |
| The site's own 404 at the home page | The bucket is empty (first deploy hasn't run) or the sync failed | Check the workflow run and `aws s3 ls` on the bucket |
| Email address shown as "[email protected]" | Cloudflare's email obfuscation, which only applies to proxied hostnames (dev) | Expected on dev only; verify on prod |

Quick outside checks that don't need a login:

```bash
curl -sI https://dev.<domain>/                 # 302 to the Access login
curl -sI https://<distribution>.cloudfront.net/ # 403: the secret-header check closes the raw address
```

## Terraform

| Symptom | Cause | Fix |
|---|---|---|
| Init asks for a bucket name | The backend is initialised without its config | `terraform init -backend-config=../../backend.hcl` |
| Cloudflare "Missing X-Auth-Key, X-Auth-Email or Authorization headers" | The API token isn't set in that shell | `read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN` |
| `AccessDenied` on an AWS action | The operator policy lacks that action | Add the action the error names, then re-run |
| Writes to the state bucket denied | A placeholder was left unreplaced in the policy | Re-read the live policy version and check both bucket statements |
| A stale state lock after an interrupted run | The run died mid-apply | `terraform force-unlock <lock id>` once you're sure nothing is running |
| `InvalidClientTokenId` right after creating an access key | The new key hasn't propagated | Wait up to a minute and retry |
| Apply fails on an existing DNS record | A same-named record already exists in Cloudflare | Delete or rename it, then apply |
| Changing `allowed_emails` also shows IAM, bucket policy and CloudFront changes, or apply fails with "Provider produced inconsistent final plan" | A module-level `depends_on` on the access module makes every data source in the site module wait until apply | Don't put `depends_on` on the module call; order resources inside the modules instead |

## Access keys and profiles

- Plain `aws configure` writes the `default` profile; pass `--profile` for a named one, and check `~/.aws/config`
  afterwards.
- Type secrets only into the prompts of the tool that needs them, never into an editor tab or a file: unsaved editor
  buffers can be exposed to other tools. If a secret ends up somewhere it shouldn't, rotate it immediately.
- `aws login` (short-lived credentials with MFA) may fail for IAM users with MFA; see the aws/aws-cli issue tracker
  (issue 10267) for the current state.
