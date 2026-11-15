# TFLint configuration for every Terraform directory in this repository (run with --recursive from terraform/).
# Modules are linted as their own directories, so module calls are not followed.
config {
  call_module_type = "none"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
