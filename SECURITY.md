# Security policy

This is a personal website and the infrastructure code behind it, published as a portfolio. There is no bug bounty, and I
reply on a best-effort basis.

## Reporting a problem

If you find something that looks like a security problem, please tell me privately instead of opening a public issue.
Examples: a leaked secret or credential in this repository, a misconfiguration in the Terraform or the workflow, or a way
to reach the private dev site without signing in.

- Use GitHub's private vulnerability reporting: the **Security** tab of this repository, then **Report a vulnerability**.
- Or email [hello@kerim-kilic.com](mailto:hello@kerim-kilic.com).

Please say what you found, where, and how to reproduce it. A simple proof is enough: please don't access other people's
data, disrupt the site, or test beyond what is needed to show the problem.

## What to expect

I'll acknowledge your report as soon as I can, fix real problems promptly, and credit you if you'd like.

## Scope

- **In scope:** kerim-kilic.com and the code, Terraform and workflows in this repository.
- **Out of scope:** the services this site runs on (AWS, Cloudflare, GitHub): please report problems in those to the
  provider. Also out of scope: denial-of-service testing and social engineering.
