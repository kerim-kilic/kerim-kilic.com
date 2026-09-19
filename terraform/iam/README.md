# IAM permissions for running Terraform

`operator-policy.tmpl.json` is the write access the person running `terraform apply` needs for this repo. It is
meant to sit **next to the AWS-managed `ReadOnlyAccess` policy**, which already covers every read Terraform does
while planning. This is for the human operator; the GitHub deploy roles Terraform creates have their own, much
smaller policy (`modules/site/github_oidc.tf`).

| Statement | Why |
|-----------|-----|
| `SiteBuckets` | Create and configure the site buckets (only names ending in `kerim-kilic-com-site`) |
| `CloudFront` | Distributions, origin access control, the CloudFront Function |
| `CertificatesInUsEast1` | ACM certificates, restricted to `us-east-1` (where CloudFront needs them) |
| `DeployRoles` | The per-environment deploy roles (only `*kerim-kilic-com-site-deploy`) |
| `GitHubOidcProvider` | The account-wide GitHub OIDC provider (`envs/shared`) |
| `TerraformStateList`, `TerraformStateObjects` | Read and write state and lock files under `kerim-kilic.com/` in the state bucket |

## Set it up

1. Fill in the two placeholders (your 12-digit account ID and the state bucket name) and print the result:

   ```bash
   sed -e 's/ACCOUNT_ID/123456789012/g' -e 's/STATE_BUCKET/your-state-bucket/g' terraform/iam/operator-policy.tmpl.json
   ```

2. In the console: **IAM > Policies > Create policy > JSON**, paste it, name it (for example
   `TerraformKerimKilicSite`), and create it.
3. Attach it to your IAM user group, together with `ReadOnlyAccess`.
4. Optional: attach the AWS-managed **`SignInLocalDevelopmentAccess`** policy only if you use `aws login` (short-lived
   console-credential sign-in) instead of a long-lived access key.

## Caveats

- **This limits mistakes, not compromise.** A policy that can create IAM roles can be used to create a more powerful
  role, so a stolen credential is still effectively admin. The protection that matters is MFA on the user and not
  leaving long-lived access keys lying around.
- **CloudFront actions use `Resource: "*"`.** Several create actions can't be scoped to a resource that doesn't exist
  yet.
- **It was derived from the Terraform code, not tested against a live account.** Every action name was checked against
  AWS's published action list, but if an apply fails with `AccessDenied`, the error names the missing action: add it to
  the right statement, re-create the policy version, and re-run.
- If you change the domain, update the `kerim-kilic-com-site` name patterns to match.

## Letting the user manage its own access key

`self-service-policy.json` lets the IAM user list its own keys, and create, deactivate or delete them **only in a session
where MFA was used** (for example a console sign-in with an authenticator code). A stolen key file alone can't mint or
delete keys. It applies only to the user's own ARN (`${aws:username}`), so it can't touch anyone else. Create it as a
customer-managed policy and attach it to the group. AWS has no managed policy for this.

To rotate: sign in to the console as the IAM user with MFA, open **Security credentials**, create a second key (two are
allowed), run `aws configure --profile kerim-website` with the new one, check it works, then deactivate and delete the
old key.
