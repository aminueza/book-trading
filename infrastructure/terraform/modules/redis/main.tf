# ElastiCache Redis module — managed Redis with replication and encryption.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.environment}-${var.cluster_id}-subnet"
  subnet_ids = var.subnet_ids

  tags = var.tags
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.environment}-${var.cluster_id}-"
  description = "Security group for Redis cluster"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis from private subnets"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Redis does not initiate outbound connections. Egress limited to DNS
  # for ElastiCache internal operations (health checks, replication discovery).
  egress {
    description = "DNS resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "DNS resolution (TCP)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  tags = merge(var.tags, {
    Name = "${var.environment}-${var.cluster_id}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.environment}-${var.cluster_id}"
  description          = "Redis cluster for ${var.environment} trading platform"

  node_type            = var.node_type
  num_cache_clusters   = var.num_cache_nodes
  port                 = 6379

  # Engine settings.
  engine               = "redis"
  engine_version       = "7.0"
  parameter_group_name = "default.redis7"

  # Networking.
  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  # HA and failover.
  automatic_failover_enabled = var.automatic_failover
  multi_az_enabled           = var.automatic_failover

  # Encryption.
  at_rest_encryption_enabled = var.at_rest_encryption
  transit_encryption_enabled = var.transit_encryption

  # Maintenance.
  maintenance_window       = var.maintenance_window
  snapshot_window          = var.snapshot_window
  snapshot_retention_limit = var.snapshot_retention

  # Prevent accidental deletion.
  apply_immediately = false

  tags = merge(var.tags, {
    Name = "${var.environment}-${var.cluster_id}"
  })

  lifecycle {
    prevent_destroy = true
  }
}
