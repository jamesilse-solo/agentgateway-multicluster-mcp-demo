resource "aws_eks_cluster" "cluster1" {
  name     = "${var.cluster_name_prefix}-cluster-1"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.33"

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  tags = {
    Name       = "${var.cluster_name_prefix}-cluster-1"
    team       = "field-engineering"
    created_by = "solo-field"
    cluster    = "cluster-1"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

resource "aws_eks_node_group" "cluster1_nodes" {
  cluster_name    = aws_eks_cluster.cluster1.name
  node_group_name = "${var.cluster_name_prefix}-cluster-1-nodes"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = [aws_subnet.private[0].id]

  scaling_config {
    desired_size = var.node_count
    max_size     = var.node_count
    min_size     = var.node_count
  }

  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"

  labels = {
    cluster    = "cluster-1"
    team       = "field-engineering"
    created_by = "solo-field"
    nodepool   = "firstnodepool"
  }

  tags = {
    Name       = "${var.cluster_name_prefix}-cluster-1-nodes"
    team       = "field-engineering"
    created_by = "solo-field"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]
}

resource "aws_eks_cluster" "cluster2" {
  name     = "${var.cluster_name_prefix}-cluster-2"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.33"

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  tags = {
    Name       = "${var.cluster_name_prefix}-cluster-2"
    team       = "field-engineering"
    created_by = "solo-field"
    cluster    = "cluster-2"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

resource "aws_eks_node_group" "cluster2_nodes" {
  cluster_name    = aws_eks_cluster.cluster2.name
  node_group_name = "${var.cluster_name_prefix}-cluster-2-nodes"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = [aws_subnet.private[0].id]

  scaling_config {
    desired_size = var.node_count
    max_size     = var.node_count
    min_size     = var.node_count
  }

  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"

  labels = {
    cluster    = "cluster-2"
    team       = "field-engineering"
    created_by = "solo-field"
    nodepool   = "firstnodepool"
  }

  tags = {
    Name       = "${var.cluster_name_prefix}-cluster-2-nodes"
    team       = "field-engineering"
    created_by = "solo-field"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]
}
