# VPC Deployment Module
# Self-contained module for creating VPC and networking infrastructure

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Use minimum of 3 AZs or all available AZs in the region
  azs = slice(data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names)))

  # vpc_name drives the Name tag on the VPC + related resources (subnets, NAT, IGW, etc.).
  # Defaults to cluster_name so single-cluster users see no diff.
  vpc_name = var.vpc_name != "" ? var.vpc_name : var.cluster_name

  # shared_cluster_names is the list of EKS clusters that will use this VPC's subnets.
  # Each cluster needs its own `kubernetes.io/cluster/<name> = shared` tag on the subnets
  # so both the cluster's control plane and its ALB Controller can discover them.
  # For single-cluster setups the list is [cluster_name].
  shared_cluster_names = length(var.shared_cluster_names) > 0 ? var.shared_cluster_names : [var.cluster_name]

  # Precomputed map of per-cluster shared tags, merged into every subnet's tags block.
  cluster_shared_tags = { for name in local.shared_cluster_names : "kubernetes.io/cluster/${name}" => "shared" }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    local.cluster_shared_tags,
    {
      Name = "${local.vpc_name}-vpc"
    }
  )
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = local.azs[count.index]

  tags = merge(
    local.cluster_shared_tags,
    {
      Name                              = "${local.vpc_name}-private-${local.azs[count.index]}"
      "kubernetes.io/role/internal-elb" = "1"
    }
  )
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index + length(local.azs))
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    local.cluster_shared_tags,
    {
      Name                     = "${local.vpc_name}-public-${local.azs[count.index]}"
      "kubernetes.io/role/elb" = "1"
    }
  )
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.vpc_name}-igw"
  }
}

resource "aws_eip" "nat" {
  count  = length(local.azs)
  domain = "vpc"

  tags = {
    Name = "${local.vpc_name}-nat-${local.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count         = length(local.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.vpc_name}-nat-${local.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.vpc_name}-public-rt"
  }
}

resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${local.vpc_name}-private-rt-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
