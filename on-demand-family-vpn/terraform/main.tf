locals {
  name_prefix = var.project_name
  # naive arch inference from instance type name
  instance_arch = contains(var.instance_type, "g.") || contains(var.instance_type, "t4g") ? "arm64" : "x86_64"
}

resource "random_password" "api_key" {
  length  = 32
  special = false
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = var.ami_owners
  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-6.1-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

data "aws_ami" "al2023_x86" {
  most_recent = true
  owners      = var.ami_owners
  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-6.1-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_vpc" "this" {
  cidr_block           = "10.99.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.99.1.0/24"
  availability_zone       = data.aws_region.current.name ~ "a"
  map_public_ip_on_launch = true
  tags = {
    Name = "${local.name_prefix}-public-a"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "vpn" {
  name        = "${local.name_prefix}-sg"
  description = "Allow WireGuard"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "WireGuard UDP"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = var.allow_cidrs_wireguard
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "ec2_ssm_policy" {
  name = "${local.name_prefix}-ec2-ssm"
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssmmessages:*", "ec2messages:*", "s3:GetObject"],
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

data "template_file" "cloud_init" {
  template = file("${path.module}/../scripts/cloud-init.yaml")
  vars = {
    project_name               = var.project_name
    wg_network_cidr            = var.wg_network_cidr
    idle_minutes_before_shutdown = var.idle_minutes_before_shutdown
  }
}

resource "aws_instance" "vpn" {
  ami           = local.instance_arch == "arm64" ? data.aws_ami.al2023_arm.id : data.aws_ami.al2023_x86.id
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.vpn.id]
  iam_instance_profile    = aws_iam_instance_profile.ec2_profile.name
  user_data                = data.template_file.cloud_init.rendered
  metadata_options {
    http_tokens = "required"
  }
  tags = {
    Name = "${local.name_prefix}-vpn"
    Project = var.project_name
  }
}

# Lambda + API for start/stop/status

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${local.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${local.name_prefix}-lambda-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:DescribeInstances",
          "route53:ChangeResourceRecordSets"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = "*"
      }
    ]
  })
}

data "archive_file" "start_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/start_instance"
  output_path = "${path.module}/../lambda/start_instance/index.zip"
}

data "archive_file" "stop_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/stop_instance"
  output_path = "${path.module}/../lambda/stop_instance/index.zip"
}

data "archive_file" "status_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/status_instance"
  output_path = "${path.module}/../lambda/status_instance/index.zip"
}

resource "aws_lambda_function" "start" {
  function_name = "${local.name_prefix}-start"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.11"
  filename      = data.archive_file.start_zip.output_path
  source_code_hash = data.archive_file.start_zip.output_base64sha256
  environment {
    variables = {
      INSTANCE_ID   = aws_instance.vpn.id
      HOSTED_ZONE_ID = var.hosted_zone_id
      RECORD_NAME   = var.record_name
      STATIC_API_KEY = random_password.api_key.result
    }
  }
}

resource "aws_lambda_function" "stop" {
  function_name = "${local.name_prefix}-stop"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.11"
  filename      = data.archive_file.stop_zip.output_path
  source_code_hash = data.archive_file.stop_zip.output_base64sha256
  environment {
    variables = {
      INSTANCE_ID   = aws_instance.vpn.id
      HOSTED_ZONE_ID = var.hosted_zone_id
      RECORD_NAME   = var.record_name
      STATIC_API_KEY = random_password.api_key.result
      PRESERVE_DNS_ON_STOP = "true"
    }
  }
}

resource "aws_lambda_function" "status" {
  function_name = "${local.name_prefix}-status"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.11"
  filename      = data.archive_file.status_zip.output_path
  source_code_hash = data.archive_file.status_zip.output_base64sha256
  environment {
    variables = {
      INSTANCE_ID   = aws_instance.vpn.id
      HOSTED_ZONE_ID = var.hosted_zone_id
      RECORD_NAME   = var.record_name
      STATIC_API_KEY = random_password.api_key.result
    }
  }
}

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "start" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.start.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "stop" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.stop.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "status" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.status.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "start" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /start"
  target    = "integrations/${aws_apigatewayv2_integration.start.id}"
}

resource "aws_apigatewayv2_route" "stop" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /stop"
  target    = "integrations/${aws_apigatewayv2_integration.stop.id}"
}

resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /status"
  target    = "integrations/${aws_apigatewayv2_integration.status.id}"
}

resource "aws_lambda_permission" "api_start" {
  statement_id  = "AllowAPIGInvokeStart"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_stop" {
  statement_id  = "AllowAPIGInvokeStop"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stop.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_status" {
  statement_id  = "AllowAPIGInvokeStatus"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}


