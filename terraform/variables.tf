variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
  default     = ""
}

variable "cluster_name_prefix" {
  description = "Prefix for cluster names"
  type        = string
  default     = "mcp-poc"
}

variable "node_instance_type" {
  description = "Instance type for EKS nodes"
  type        = string
  default     = "t3.large"
}

variable "node_count" {
  description = "Number of nodes per cluster"
  type        = number
  default     = 1
}
