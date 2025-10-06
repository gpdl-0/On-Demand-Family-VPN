# On-Demand Family VPN on AWS (WireGuard + AdGuard Home)

This repository provisions an on-demand, cost-efficient personal/family VPN with privacy-focused DNS filtering. It uses AWS to spin up a secure WireGuard VPN and AdGuard Home DNS filter only when needed, then tears it down or auto-stops when idle to minimize costs.

## Highlights

- Minimal idle cost; compute exists only on demand
- One-click API to start/stop/status via managed endpoint
- Security-first: private admin, least-privilege IAM, SSM access; no SSH
- Network-wide privacy with AdGuard Home DNS filtering
- 100% Infrastructure as Code with Terraform

## Architecture Overview

Components:

- VPC with a single public subnet for a small EC2 instance (t4g.nano/t3a.nano)
- Security Group exposes only WireGuard UDP (51820). No public SSH. Admin via AWS SSM Session Manager
- EC2 boots with cloud-init to install: WireGuard (kernel) and AdGuard Home (Docker)
- AdGuard Home listens only on the WireGuard interface; admin UI accessible over VPN or SSM port-forward
- Lambda functions (Start/Stop/Status) fronted by API Gateway HTTP API
  - Start: Starts EC2, waits for public IP, UPSERTs Route53 A record (e.g. `vpn.example.com`)
  - Stop: Stops EC2 and DELETEs DNS record
  - Status: Reports instance state and DNS
- Route53 public hosted zone for friendly VPN endpoint
- SSM Parameter Store (SecureString) to store WireGuard keys and AdGuard credentials generated on first boot
- On-instance idle shutdown via systemd timer that inspects WireGuard handshakes and shuts down when idle

Security notes:

- No SSH open to the internet; use SSM Session Manager for break-glass
- Admin surfaces bound to localhost or WireGuard interface only
- IAM policies are scoped to exact resources (instance ID, hosted zone)
- Secrets never hard-coded; generated and stored in SSM

Cost profile:

- Idle: pennies/month (Route53 zone + parameter storage)
- Active: EC2 instance, egress traffic
- No Elastic IP allocated to avoid idle charges; DNS points to ephemeral public IP on start

## Repository Structure

```
terraform/
  versions.tf
  providers.tf
  variables.tf
  main.tf
  outputs.tf
lambda/
  start_instance/index.py
  stop_instance/index.py
  status_instance/index.py
scripts/
  cloud-init.yaml
  wg-idle-shutdown.sh
  adguard-docker-compose.yaml
```

## Prerequisites

- AWS account and Route53 hosted zone (e.g. `example.com`)
- Terraform >= 1.5, AWS CLI configured
- Optional: an `aws_profile` configured locally

## Quick Start

1) Clone and configure variables

```
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
``` 

Set at minimum:

- `project_name` (e.g., "family-vpn")
- `region`
- `hosted_zone_id`
- `record_name` (e.g., `vpn.example.com`)
- `instance_type` (defaults sensible)

2) Initialize and apply

```
cd terraform
terraform init
terraform apply -auto-approve
```

3) Use the API to start the VPN

The output includes an API endpoint and optional API key. Start:

```
curl -X POST "$API_ENDPOINT/start" -H "x-api-key: $API_KEY"
```

Within ~60-120 seconds the instance is ready, DNS is updated, and WireGuard is listening on UDP 51820. Connect using the client configuration generated on first boot (see below).

4) Retrieve WireGuard client configs

On first boot, the instance generates server and a default `family` peer config and stores them under SSM Parameter Store paths:

- `/on_demand_vpn/wg/server_public_key`
- `/on_demand_vpn/wg/server_private_key`
- `/on_demand_vpn/wg/client_family_conf`

You can retrieve with AWS CLI or extend the `status` Lambda to return a pre-signed link or the config content.

5) Stop when done

```
curl -X POST "$API_ENDPOINT/stop" -H "x-api-key: $API_KEY"
```

The instance will also auto-shutdown when idle (no WireGuard handshakes for N minutes).

## Incremental Development Plan

1) MVP
- VPC, subnet, SG
- EC2 with WireGuard via cloud-init, minimal peer
- Manual start/stop via console

2) On-demand API
- Lambdas: start/stop/status
- API Gateway HTTP API routes
- Route53 DNS automation

3) Privacy DNS
- AdGuard Home via Docker bound to WireGuard interface
- WireGuard clients use AdGuard IP as DNS

4) Hardening & Secrets
- IAM least-privilege policies
- SSM Parameter Store for secrets and configs
- Remove any public admin surfaces; use SSM port-forward

5) Automation & UX
- Idle shutdown timer
- API Key on API Gateway
- Optional: GitHub Actions to run `terraform plan` on PRs

## Operations

- To access AdGuard Home admin: establish SSM port-forward to `localhost:3000` or connect over VPN and open `http://10.44.0.1:3000` (default port configured in cloud-init). Credentials are stored in SSM at `/on_demand_vpn/adguard/admin_password`.
- Logs: review EC2 cloud-init logs and AdGuard Docker logs via SSM Session Manager.
- To change peers: update WireGuard config via SSM automation or port-forward and adjust on instance; extend automation as desired.

## Disclaimer

This project is for educational purposes. Review AWS costs, security posture, and regional service availability before production use.


