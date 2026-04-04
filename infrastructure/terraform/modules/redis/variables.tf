variable "environment" {
  type = string
}

variable "cluster_id" {
  type = string
}

variable "node_type" {
  type    = string
  default = "cache.r6g.large"
}

variable "num_cache_nodes" {
  type    = number
  default = 2
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_cidr_blocks" {
  type = list(string)
}

variable "at_rest_encryption" {
  type    = bool
  default = true
}

variable "transit_encryption" {
  type    = bool
  default = true
}

variable "automatic_failover" {
  type    = bool
  default = true
}

variable "maintenance_window" {
  type    = string
  default = "sun:04:00-sun:06:00"
}

variable "snapshot_window" {
  type    = string
  default = "02:00-04:00"
}

variable "snapshot_retention" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
