key          = "devops-task/prod/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true # native S3 state locking (no DynamoDB table needed)
