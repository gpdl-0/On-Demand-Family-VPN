variable "project_name" {
  description = "Project name prefix for tagging and resource names"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "aws_profile" {
  description = "Optional AWS named profile"
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route53 Hosted Zone ID for DNS updates"
  type        = string
}

variable "record_name" {
  description = "FQDN for the VPN endpoint, e.g. vpn.example.com"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t4g.nano"
}

variable "allow_cidrs_wireguard" {
  description = "CIDR blocks allowed to reach WireGuard UDP 51820"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "idle_minutes_before_shutdown" {
  description = "Minutes of no WireGuard handshakes before auto-shutdown"
  type        = number
  default     = 30
}

variable "wg_network_cidr" {
  description = "WireGuard VPN network CIDR"
  type        = string
  default     = "10.44.0.0/24"
}

variable "ami_owners" {
  description = "AMI owners filter"
  type        = list(string)
  default     = ["137112412989"] # Amazon Linux
}


