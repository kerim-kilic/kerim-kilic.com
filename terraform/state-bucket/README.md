# Terraform state bucket

Created once by hand, as root (or an admin), because Terraform can't create the bucket that holds its own state.
The operator policy in `../iam/` deliberately can't change this bucket's settings or policy: only read and write the
state objects. Changing the bucket later is a root/admin task.

Console wording changes from time to time; the settings matter, not the exact labels.

1. Sign in as root (with MFA). In the region selector choose **Europe (Frankfurt) eu-central-1**, matching `backend.hcl`.
2. **S3 > Create bucket > General purpose.**
3. **Bucket name:** globally unique, for example `<something>-tfstate-eu-central-1-<random>`. The name is not secret, but it must
   **not** end in `kerim-kilic-com-site`.
4. **Object Ownership:** *ACLs disabled (Bucket owner enforced)*.
5. **Block Public Access:** leave **all four** boxes ticked.
6. **Bucket Versioning:** *Enable*.
7. **Default encryption:** *SSE-S3* (Amazon S3 managed keys). Using KMS instead would need extra permissions in the operator policy.
8. **Object Lock:** leave disabled. Optionally add the tag `Project = terraform-state`.
9. **Create bucket.**
10. **Permissions > Bucket policy > Edit:** paste `bucket-policy.tmpl.json` with `STATE_BUCKET` replaced by the bucket name
    (it denies any non-HTTPS request), then save.
11. **Management > Create lifecycle rule** named `expire-old-state-versions`, applied to all objects, with:
    - *Permanently delete noncurrent versions of objects* after 90 days, keeping the newest 10 noncurrent versions.
    - *Delete expired object delete markers or incomplete multipart uploads*: both ticked, incomplete uploads after 7 days.
12. Check the **Properties** tab (versioning enabled, default encryption SSE-S3) and **Permissions** tab (all public access blocked).
13. Put the bucket name in `terraform/backend.hcl`, and in the `STATE_BUCKET` placeholder of the operator policy.

Terraform then writes state under `kerim-kilic.com/<env>/terraform.tfstate` and a `.tflock` object next to it while it runs.
