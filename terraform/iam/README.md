# IAM permissions for running Terraform

`operator-policy.tmpl.json` is the write access the person running `terraform apply` needs for this repo. It is
meant to sit **next to the AWS-managed `ReadOnlyAccess` policy**, which already covers every read Terraform does
while planning. This is for the human operator; the GitHub deploy roles Terraform creates have their own, much
smaller policy (`modules/site/github_oidc.tf`).

| Statement | Why |
|-----------|-----|
| `SiteBuckets` | Create and configure the site buckets (only names ending in `kerim-kilic-com-site`) |
| `CloudFront` | Distributions, origin access control, the CloudFront Function, the security response-headers policy |
| `CertificatesInUsEast1` | ACM certificates, restricted to `us-east-1` (where CloudFront needs them) |
| `DeployRoles` | Update, tag and delete the per-environment deploy roles (only `*kerim-kilic-com-site-deploy`) |
| `DeployRolesWithBoundary` | Create those roles and write their policies, only while `website-deploy-boundary` is their permissions boundary |
| `GitHubOidcProvider` | The account-wide GitHub OIDC provider (`envs/shared`) |
| `TerraformStateList`, `TerraformStateObjects` | Read and write state and lock files under `kerim-kilic.com/` in the state bucket |

## Set it up

Create the deploy boundary first, because the operator policy refers to it.

1. Fill in the account ID in `deploy-boundary.tmpl.json` and print the result:

   ```bash
   sed -e 's/ACCOUNT_ID/123456789012/g' terraform/iam/deploy-boundary.tmpl.json
   ```

   In the console, **as a different identity than the operator** (for example root): **IAM > Policies > Create
   policy > JSON**, paste it, name it exactly `website-deploy-boundary`, and create it.
2. Fill in the two placeholders (your 12-digit account ID and the state bucket name) and print the result:

   ```bash
   sed -e 's/ACCOUNT_ID/123456789012/g' -e 's/STATE_BUCKET/your-state-bucket/g' terraform/iam/operator-policy.tmpl.json
   ```

3. In the console: **IAM > Policies > Create policy > JSON**, paste it, name it (for example
   `TerraformKerimKilicSite`), and create it.
4. Attach it to your IAM user group, together with `ReadOnlyAccess`.
5. Optional: attach the AWS-managed **`SignInLocalDevelopmentAccess`** policy only if you use `aws login` (short-lived
   console-credential sign-in) instead of a long-lived access key.

## The deploy boundary

`deploy-boundary.tmpl.json` is a permissions boundary: the most a deploy role can ever do, whatever policies it is
given. It allows exactly what the deploy job needs: list the site buckets, put and delete their objects, and create
CloudFront invalidations. Terraform sets it on every deploy role (`permissions_boundary` in
`modules/site/github_oidc.tf`).

The operator policy can only create a deploy role, write its inline policy or set its boundary when that boundary is
`website-deploy-boundary`. It has no `iam:DeleteRolePermissionsBoundary`, `iam:AttachRolePolicy` or
`iam:CreatePolicyVersion`, so it can neither remove the boundary nor widen it.

## Caveats

- **This limits mistakes, and now limits compromise too, but not completely.** Without the boundary, a policy that can
  create IAM roles and write their policies could make an admin role. With it, a role the operator creates or changes
  can never do more than deploy the site. What is left: the operator can still change a deploy role's trust policy, so
  a stolen operator key could let another identity assume a deploy role, but only with the boundary's permissions
  (write to the site buckets and invalidate their caches). The operator policy itself can still change the site's
  buckets, distributions and certificates. MFA on the user and short-lived access keys remain the real protection.
- **CloudFront actions use `Resource: "*"`.** Several create actions can't be scoped to a resource that doesn't exist
  yet.
- **It was derived from the Terraform code**, and every action name was checked against AWS's published action list. It
  has been used to apply the dev environment. If an apply fails with `AccessDenied`, the error names the missing action:
  add it to the right statement, re-create the policy version, and re-run.
- If you change the domain, update the `kerim-kilic-com-site` name patterns to match.

## Letting the user manage its own access key

`self-service-policy.json` lets the IAM user list its own keys, and create, deactivate or delete them **only in a session
where MFA was used** (for example a console sign-in with an authenticator code). A stolen key file alone can't mint or
delete keys. It applies only to the user's own ARN (`${aws:username}`), so it can't touch anyone else. Create it as a
customer-managed policy and attach it to the group. AWS has no managed policy for this.

To rotate: sign in to the console as the IAM user with MFA, open **Security credentials**, create a second key (two are
allowed), run `aws configure --profile kerim-website` with the new one, check it works, then deactivate and delete the
old key.
