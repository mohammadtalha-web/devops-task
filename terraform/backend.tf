# Partial configuration: bucket/key/region come from `-backend-config` at init time so the same
# code serves both environments with separate state files:
#   terraform init -backend-config=envs/staging.backend.hcl -backend-config="bucket=<state-bucket>"
terraform {
  backend "s3" {}
}
