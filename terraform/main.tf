provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, Environment = var.environment, ManagedBy = "terraform" }
  }
}

locals {
  name      = "${var.project}-${var.environment}"
  log_group = "/${var.project}/${var.environment}/app"
}

data "aws_caller_identity" "current" {}
data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Latest Amazon Linux 2023 (resolved at plan time; `ignore_changes = [ami]` stops churn later).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

# ---------------------------------------------------------------- logging
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- network
resource "aws_security_group" "app" {
  name_prefix = "${local.name}-"
  description = "App instance: app port in, HTTPS out. No SSH (use SSM Session Manager)."
  vpc_id      = data.aws_vpc.default.id
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "App traffic"
  cidr_ipv4         = each.value
  from_port         = var.app_port
  to_port           = var.app_port
  ip_protocol       = "tcp"
}

# HTTPS only: ECR, CloudWatch Logs, SSM and OS package repos are all reachable over 443.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs and package repos"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ---------------------------------------------------------------- IAM (instance profile, no static keys)
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Lets SSM run the deploy command (and Session Manager replace SSH).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPullOnly"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
    resources = [data.aws_ecr_repository.app.arn]
  }
  statement {
    sid       = "WriteAppLogsOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "app-runtime"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------- compute
resource "aws_instance" "app" {
  ami                    = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type          = var.instance_type
  subnet_id              = sort(tolist(data.aws_subnets.default.ids))[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region        = var.region
    log_group     = local.log_group
    app_port      = var.app_port
    environment   = var.environment
    log_level     = var.log_level
    initial_image = var.initial_image_tag == "" ? "" : "${data.aws_ecr_repository.app.repository_url}:${var.initial_image_tag}"
    deploy_script = base64gzip(file("${path.module}/../scripts/deploy-app.sh"))
    health_script = base64gzip(file("${path.module}/../scripts/system_health.sh"))
    health_unit   = base64gzip(file("${path.module}/../scripts/systemd/system-health.service"))
    health_timer  = base64gzip(file("${path.module}/../scripts/systemd/system-health.timer"))
  })
  user_data_replace_on_change = true

  tags = { Name = local.name }

  lifecycle { ignore_changes = [ami] }
}
