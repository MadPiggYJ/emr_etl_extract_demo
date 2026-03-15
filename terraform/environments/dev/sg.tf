# ══════════════════════════════════════════════════════════════════════════════
# Security Groups
# ══════════════════════════════════════════════════════════════════════════════

# SG for VPC Interface Endpoints (SSM + Secrets Manager)
# 只允许 VPC 内 HTTPS 流量进入 endpoint
resource "aws_security_group" "endpoints" {
  name        = "${local.project_name}-endpoints-sg"
  description = "VPC interface endpoints - allow HTTPS from within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
} # ingress 443的 egress return traffic自动允许，endpoint 到 aws service 的egress 因为服务ip动态 不公开 所以限制没有意

# RDS SG — 只接受来自 EMR master 和 core 的 5432
# 不开任何公网入站
# inline rule 造成了循环错误 rds sg ingress 依赖 master/slave sg 建立 master/slave egress 依赖rds sg 建立 master 和 slave之间 通信又互相依赖
# 跨 SG 的 ingress 规则拆到下方 aws_security_group_rule，避免循环依赖
# 被访问对象需要ingress rule, 访问对象需要egress rule
resource "aws_security_group" "rds" {
  name        = "${local.project_name}-rds-sg"
  description = "RDS PostgreSQL - ingress from EMR nodes only"
  vpc_id      = module.vpc.vpc_id
}

# EMR Master SG
# 出站：443 → SSM endpoint，5432 → RDS，全部 → core 节点
# 入站：不开 22（用 SSM 登录，无需 SSH）
# 注意：跨 SG 的 egress 规则拆到下方 aws_security_group_rule，避免循环依赖
resource "aws_security_group" "emr_master" {
  name        = "${local.project_name}-emr-master-sg"
  description = "EMR master - outbound to RDS and SSM, no inbound SSH"
  vpc_id      = module.vpc.vpc_id
}

# EMR Slave (core) SG
# 出站：443 → SSM，5432 → RDS，全部 → master
# 注意：跨 SG 的 egress 规则拆到下方 aws_security_group_rule，避免循环依赖
resource "aws_security_group" "emr_slave" {
  name        = "${local.project_name}-emr-slave-sg"
  description = "EMR core nodes - outbound to RDS, master, SSM"
  vpc_id      = module.vpc.vpc_id
}

# EMR Service Access SG — 私有子网必须有，EMR 控制平面用这个管理集群
# 不加这个，EMR 在私有子网里会启动失败
# 注意：跨 SG 的 egress 规则拆到下方 aws_security_group_rule，避免循环依赖
resource "aws_security_group" "emr_service_access" {
  name        = "${local.project_name}-emr-service-access-sg"
  description = "EMR service access - required for private subnet clusters"
  vpc_id      = module.vpc.vpc_id
}

# ══════════════════════════════════════════════════════════════════════════════
# Cross-SG rules (拆出来避免循环依赖)
# ══════════════════════════════════════════════════════════════════════════════

resource "aws_security_group_rule" "master_egress_https" {
  type              = "egress"
  description       = "HTTPS to VPC endpoints"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.emr_master.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "slave_egress_https" {
  type              = "egress"
  description       = "HTTPS to VPC endpoints"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.emr_slave.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "rds_ingress_from_master" {
  type                     = "ingress"
  description              = "PostgreSQL from EMR master"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.emr_master.id
}

resource "aws_security_group_rule" "rds_ingress_from_slave" {
  type                     = "ingress"
  description              = "PostgreSQL from EMR core"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.emr_slave.id
}

resource "aws_security_group_rule" "master_egress_to_rds" {
  type                     = "egress"
  description              = "PostgreSQL to RDS"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_master.id
  source_security_group_id = aws_security_group.rds.id
}

resource "aws_security_group_rule" "master_ingress_from_slave" {
  type                     = "ingress"
  description              = "All traffic from EMR core"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.emr_master.id
  source_security_group_id = aws_security_group.emr_slave.id
}

resource "aws_security_group_rule" "master_egress_to_slave" {
  type                     = "egress"
  description              = "All traffic to core nodes"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.emr_master.id
  source_security_group_id = aws_security_group.emr_slave.id
}

resource "aws_security_group_rule" "slave_egress_to_rds" {
  type                     = "egress"
  description              = "PostgreSQL to RDS"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_slave.id
  source_security_group_id = aws_security_group.rds.id
}

resource "aws_security_group_rule" "slave_ingress_from_master" {
  type                     = "ingress"
  description              = "All traffic from EMR master"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.emr_slave.id
  source_security_group_id = aws_security_group.emr_master.id
}


resource "aws_security_group_rule" "slave_egress_to_master" {
  type                     = "egress"
  description              = "All traffic to master"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.emr_slave.id
  source_security_group_id = aws_security_group.emr_master.id
}

resource "aws_security_group_rule" "service_access_egress_to_master" {
  type                     = "egress"
  description              = "HTTPS to EMR master (control plane)"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_service_access.id
  source_security_group_id = aws_security_group.emr_master.id
}

resource "aws_security_group_rule" "service_access_egress_to_slave" {
  type                     = "egress"
  description              = "HTTPS to EMR slave (control plane)"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_service_access.id
  source_security_group_id = aws_security_group.emr_slave.id
}

resource "aws_security_group_rule" "master_ingress_from_service_access" {
  type                     = "ingress"
  description              = "EMR control plane (8443) from service access SG"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_master.id
  source_security_group_id = aws_security_group.emr_service_access.id
}

resource "aws_security_group_rule" "slave_ingress_from_service_access" {
  type                     = "ingress"
  description              = "EMR control plane (8443) from service access SG"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_slave.id
  source_security_group_id = aws_security_group.emr_service_access.id
}
# EMR 5.30.0 开始，AWS 修改了网络模型, 如果用自定义的 managed security groups
resource "aws_security_group_rule" "master_egress_to_service_access" {
  type                     = "egress"
  description              = "EMR master to service access on port 9443"
  from_port                = 9443
  to_port                  = 9443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_master.id
  source_security_group_id = aws_security_group.emr_service_access.id
}

resource "aws_security_group_rule" "service_access_ingress_from_master" {
  type                     = "ingress"
  description              = "EMR master to service access on port 9443"
  from_port                = 9443
  to_port                  = 9443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_service_access.id
  source_security_group_id = aws_security_group.emr_master.id
}