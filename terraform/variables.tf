variable "project" {
  type    = string
  default = "devops-task"
}

variable "environment" {
  type        = string
  description = "Environment name; drives naming, tags, log retention and sizing."
  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be \"staging\" or \"prod\"."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro" # Free Tier eligible in most regions
}

variable "root_volume_gb" {
  type    = number
  default = 12
}

variable "app_port" {
  type    = number
  default = 8080
}

variable "allowed_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the app port. Keep as narrow as possible."
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "ecr_repository_name" {
  type    = string
  default = "devops-task-app"
}

variable "initial_image_tag" {
  type        = string
  default     = ""
  description = "Optional tag to deploy at first boot. Empty = wait for the first CI deploy."
}
