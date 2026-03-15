# terraform/modules/vpc/main.tf

data "aws_availability_zones" "available" { state = "available" }

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
} # 数组slice 相当与 names[0:2] 左包右不包

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true   # required for VPC Interface Endpoints # 之后要做private subnet-> aws服务的数据出口 # 打开之后private subnet 内的资源可以分配hostname
  enable_dns_support   = true   # 允许VPC内dns解析 只有开启之后才能让endpoint的private dns enable 生效，分配内部ip

  tags = merge(var.tags, { Name = "${var.vpc_name}-vpc" })
}

# ── Public subnets (NAT Gateway only) ────────────────────────────────────────
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, { Name = "${var.vpc_name}-public-${count.index + 1}" })
}

# ── Private subnets (EMR + RDS live here) ────────────────────────────────────
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, { Name = "${var.vpc_name}-private-${count.index + 1}" })
} # 建立子网其实用each更好 防止之后资源飘移

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.vpc_name}-igw" })
}

# ── NAT Gateway (one, for private subnet outbound if needed) ─────────────────
resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0 # count 三元 判断用来决定是否创建nat
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.vpc_name}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  count         = var.enable_nat ? 1 : 0 # count 判断用来决定是否创建nat
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(var.tags, { Name = "${var.vpc_name}-nat" })
  depends_on    = [aws_internet_gateway.igw]
}

# ── Route tables ──────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(var.tags, { Name = "${var.vpc_name}-public-rt" })
} # 创建public子网到igw的route table

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.enable_nat ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.nat[0].id
    }
  }

  tags = merge(var.tags, { Name = "${var.vpc_name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ══════════════════════════════════════════════════════════════════════════════
# VPC Endpoints — 私有子网不需要 NAT 就能访问 AWS 服务
# ══════════════════════════════════════════════════════════════════════════════
# S3 和 dynamoDB 可以走gateway endpoint, 其他服务需要走eni interface
# S3 Gateway Endpoint (free, no SG needed)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(var.tags, { Name = "${var.vpc_name}-s3-endpoint" })
}

# SSM Interface Endpoints — 允许私有子网 EC2 通过 SSM Session Manager 登录
# 三个都需要，缺一不可 # endpoint 可以抽成module 方便管理
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.endpoint_sg_id]
  private_dns_enabled = true # dns 给endpoint 分配 VPC 内 private IP
  tags                = merge(var.tags, { Name = "${var.vpc_name}-ssm-endpoint" })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.endpoint_sg_id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.vpc_name}-ssmmessages-endpoint" })
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.endpoint_sg_id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.vpc_name}-ec2messages-endpoint" })
}

# Secrets Manager Interface Endpoint
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.endpoint_sg_id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.vpc_name}-sm-endpoint" })
}

# EMR Interface Endpoint — EMR agent 向 EMR 服务注册需要
resource "aws_vpc_endpoint" "emr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.elasticmapreduce"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [var.endpoint_sg_id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.vpc_name}-emr-endpoint" })
}
