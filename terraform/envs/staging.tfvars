environment        = "staging"
instance_type      = "t3.micro"
log_retention_days = 7
log_level          = "debug"
# Replace with your own public IP: curl -s https://checkip.amazonaws.com
allowed_cidrs = ["0.0.0.0/0"]
