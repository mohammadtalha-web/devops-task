environment        = "prod"
instance_type      = "t3.small"
root_volume_gb     = 16
log_retention_days = 30
log_level          = "info"
# Production: put an ALB in front and allow only the ALB security group / office CIDRs here.
allowed_cidrs = ["0.0.0.0/0"]
