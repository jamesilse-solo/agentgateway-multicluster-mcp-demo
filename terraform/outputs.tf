output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "cluster1_endpoint" {
  description = "Endpoint for EKS cluster 1"
  value       = aws_eks_cluster.cluster1.endpoint
}

output "cluster1_security_group_id" {
  description = "Security group ID attached to the EKS cluster 1"
  value       = aws_eks_cluster.cluster1.vpc_config[0].cluster_security_group_id
}

output "cluster1_name" {
  description = "Name of EKS cluster 1"
  value       = aws_eks_cluster.cluster1.name
}

output "cluster2_endpoint" {
  description = "Endpoint for EKS cluster 2"
  value       = aws_eks_cluster.cluster2.endpoint
}

output "cluster2_security_group_id" {
  description = "Security group ID attached to the EKS cluster 2"
  value       = aws_eks_cluster.cluster2.vpc_config[0].cluster_security_group_id
}

output "cluster2_name" {
  description = "Name of EKS cluster 2"
  value       = aws_eks_cluster.cluster2.name
}

output "region" {
  description = "AWS region"
  value       = var.region
}
