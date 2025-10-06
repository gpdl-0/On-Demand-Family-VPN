output "api_endpoint" {
  value       = aws_apigatewayv2_api.http.api_endpoint
  description = "Base URL for the HTTP API"
}

output "api_key" {
  value       = nonsensitive(random_password.api_key.result)
  description = "Static API key required in 'x-api-key' header"
}

output "instance_id" {
  value       = aws_instance.vpn.id
  description = "EC2 instance ID for the VPN server"
}


