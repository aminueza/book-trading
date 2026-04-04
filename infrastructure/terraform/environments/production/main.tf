# Production environment — composed from shared modules.
#
# Design decisions:
#
# 1. Module composition over monolithic config:
#    Each infrastructure concern (VPC, EKS, Redis, monitoring) is a separate
#    module with explicit inputs/outputs. This enables:
#    - Independent review and testing of each component
#    - Selective apply during incidents (e.g., only change monitoring)
#    - Clear ownership boundaries when multiple teams contribute
#
# 2. Remote state with locking:
#    S3 + DynamoDB backend prevents concurrent applies that could corrupt state.
#    State is encrypted at rest and versioned for rollback.
#
# 3. Blast radius containment:
#    - Separate state files per environment prevent staging changes from
#      affecting production.
#    - plan-only CI for PRs; apply requires manual approval.
#    - Sentinel/OPA policies (referenced but not implemented here) would
#      block dangerous changes like deleting subnets or disabling encryption.
#
# 4. What would change for multi-team:
#    - Each team gets its own state file and module directory.
#    - CODEOWNERS enforces review requirements per directory.
#    - A shared "platform" module provides VPC, EKS, and IAM baselines.
#    - Teams consume platform outputs via terraform_remote_state data sources.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  backend "s3" {
    bucket         = "trading-platform-tfstate"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-lock"
    # In production, also configure:
    # kms_key_id = "arn:aws:kms:..."  # Customer-managed KMS key
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "production"
      ManagedBy   = "terraform"
      Team        = "sre"
      Service     = "trading-platform"
    }
  }
}

# --- Data sources ---
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC ---
module "vpc" {
  source = "../../modules/vpc"

  environment        = "production"
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)

  # Private subnets for EKS nodes; public subnets for NLB/ALB.
  private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false  # One per AZ for production HA

  tags = {
    "kubernetes.io/cluster/trading-production" = "shared"
  }
}

# --- EKS Cluster ---
module "eks" {
  source = "../../modules/eks"

  environment    = "production"
  cluster_name   = "trading-production"
  cluster_version = "1.29"

  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnet_ids

  # Node groups — separate pools for system and application workloads.
  # This prevents application resource pressure from affecting cluster
  # system components (CoreDNS, kube-proxy, etc.)
  node_groups = {
    system = {
      instance_types = ["m6i.large"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels = {
        "node-role" = "system"
      }
      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
    trading = {
      instance_types = ["c6i.xlarge"]  # Compute-optimized for trading workloads
      min_size       = 3
      max_size       = 12
      desired_size   = 3
      labels = {
        "node-role" = "trading"
      }
      taints = []
    }
  }

  # Cluster add-ons managed by EKS for automatic patching.
  enable_cluster_addons = true

  tags = {
    Component = "compute"
  }
}

# --- Redis (ElastiCache) ---
module "redis" {
  source = "../../modules/redis"

  environment     = "production"
  cluster_id      = "trading-cache"
  node_type       = "cache.r6g.large"
  num_cache_nodes = 2  # Primary + 1 replica for HA

  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids
  allowed_cidr_blocks = module.vpc.private_subnet_cidrs

  # Enable encryption in transit and at rest.
  at_rest_encryption = true
  transit_encryption = true

  # Automatic failover for production.
  automatic_failover = true

  # Maintenance window outside trading hours (UTC).
  maintenance_window = "sun:04:00-sun:06:00"
  snapshot_window    = "02:00-04:00"
  snapshot_retention = 7

  tags = {
    Component = "cache"
  }
}

# --- Monitoring ---
module "monitoring" {
  source = "../../modules/monitoring"

  environment  = "production"
  cluster_name = module.eks.cluster_name

  # Alert destinations.
  pagerduty_endpoint  = var.pagerduty_endpoint
  slack_webhook_url   = var.slack_webhook_url

  # Log retention — 90 days for production (compliance requirement).
  log_retention_days = 90

  tags = {
    Component = "observability"
  }
}

# --- Outputs ---
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "eks_cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "redis_endpoint" {
  value     = module.redis.primary_endpoint
  sensitive = true
}
