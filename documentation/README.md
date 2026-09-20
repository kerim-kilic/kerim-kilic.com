# Documentation

Technical documentation for how this site is built and run.

| Document | What it covers |
|----------|----------------|
| [`architecture.md`](architecture.md) | How the site works: request path, environments, Terraform layout, access control, deployment, and the decisions behind them |
| [`troubleshooting.md`](troubleshooting.md) | Symptoms, causes and fixes for the deploy pipeline, the dev site and Terraform |
| [`terraform/iam/`](../terraform/iam/README.md) | The permissions the person running Terraform needs, and the self-service key policy |
| [`terraform/state-bucket/`](../terraform/state-bucket/README.md) | How the Terraform state bucket is created and locked down |

Operational commands (apply order, repository variables, the go-live checklist) are in the top-level
[`README.md`](../README.md). The article "How this website works" on the site explains the design for a general audience.
