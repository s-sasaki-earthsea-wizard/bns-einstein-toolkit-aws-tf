# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Network layer for the GW230529 spot compute node.
#
# Design note -- why a public subnet:
#   The node needs outbound access for the SSM agent (443) and inbound access
#   for nothing at all. The two private-subnet options both cost real money
#   against a 300 USD project budget:
#
#     NAT gateway                            ~33 USD/month + data processing
#     Interface endpoints x5 (ssm,           ~36 USD/month
#       ssmmessages, ec2messages,
#       ecr.api, ecr.dkr)
#
#   A public subnet with an empty ingress rule set costs 0 USD/month and has
#   the same effective exposure: no port is reachable. S3 traffic bypasses the
#   internet gateway entirely through the (free) gateway endpoint, which also
#   removes any chance of paying egress on a checkpoint sync.

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # An explicit list wins. The fallback orders zones by name, which has nothing
  # to do with where spot capacity is: in us-west-2 the first three names are
  # a, b and c, which omits the highest scoring zone (us-west-2d, usw2-az4) and
  # includes the one that scores nothing (us-west-2b, usw2-az1). Name order is
  # a fine default only because subnets are free -- it is not a placement
  # decision, so a production deployment should pass availability_zones.
  azs = (
    var.availability_zones != null
    ? var.availability_zones
    : slice(data.aws_availability_zones.available.names, 0, var.az_count)
  )
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# The CIDR of each subnet comes from its position in local.azs, so reordering
# the zone list replaces every subnet. Append rather than reorder.
resource "aws_subnet" "public" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${each.key}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route" "default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Gateway endpoint for S3. Free, and it keeps `aws s3 sync` traffic off the
# internet gateway so a misconfigured bucket region cannot generate egress.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = {
    Name = "${var.name_prefix}-s3-endpoint"
  }
}

data "aws_region" "current" {}

# No ingress rules at all. Operator access is via SSM Session Manager, which
# is an outbound-initiated connection.
resource "aws_security_group" "node" {
  name        = "${var.name_prefix}-node"
  description = "GW230529 compute node: outbound only, no inbound"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-node"
  }
}

resource "aws_vpc_security_group_egress_rule" "all_ipv4" {
  security_group_id = aws_security_group.node.id
  description       = "Allow all outbound (SSM, ECR, S3, package mirrors)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
