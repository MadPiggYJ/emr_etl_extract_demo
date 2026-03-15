# EMR ETL 项目踩坑记录

记录本次项目从零部署到跑通 PySpark 作业过程中遇到的所有问题及解决方案。

---

## 1. Terraform 安全组循环依赖

**错误**
```
Error: Cycle: aws_security_group.emr_slave, aws_security_group.emr_master, aws_security_group.rds
```

**原因**
安全组 A 的 inline `ingress` 引用了安全组 B，安全组 B 的 inline `ingress` 又引用了安全组 A，Terraform 无法确定创建顺序。

**解决**
把 inline 的 `ingress`/`egress` 全部拆成独立的 `aws_security_group_rule` 资源。`aws_security_group` 只定义 SG 本身，规则单独写，不存在顺序依赖。

```hcl
# 不要这样：
resource "aws_security_group" "master" {
  ingress {
    security_groups = [aws_security_group.slave.id]  # 循环！
  }
}

# 改成这样：
resource "aws_security_group_rule" "master_ingress_from_slave" {
  type                     = "ingress"
  security_group_id        = aws_security_group.master.id
  source_security_group_id = aws_security_group.slave.id
  ...
}
```

---

## 2. 安全组描述包含非 ASCII 字符被 AWS 拒绝

**错误**
```
ValidationException: Security group rule description must match regex [a-zA-Z0-9 ._\-:/()#,@\[\]+=&;{}!$*]
```

**原因**
`description` 字段用了中文破折号 `—`（em dash，U+2014），AWS 只接受 ASCII。

**解决**
全部改成英文连字符 `-`。写安全组描述时不要用任何中文字符或特殊 Unicode 符号。

---

## 3. SubscriptionRequiredException — EMR 服务未激活

**错误**
```
SubscriptionRequiredException: The account is not subscribed to this service
```

**原因**
新 AWS 账号首次使用 EMR 需要在控制台手动激活服务。

**解决**
登录 AWS Console → 进入 EMR 页面 → 点击激活/同意条款。之后 `terraform apply` 就能正常创建 EMR 集群。

---

## 4. EMR 实例类型在当前区域无容量

**错误**
集群状态变为 `TERMINATED_WITH_ERRORS`，事件日志提示 `m5.large` 没有可用容量。

**原因**
新账号在 ap-southeast-2 的部分 AZ 对 m5 系列有容量限制或未开通。

**解决**
改用 `m4.large`：

```hcl
variable "emr_master_instance_type" {
  default = "m4.large"
}
```

---

## 5. BOOTSTRAP_FAILURE — service_access_security_group 缺少 9443 入站规则

**错误**
```
BOOTSTRAP_FAILURE
On the master instance(s), bootstrap action 2 failed
```

**原因**
EMR 私有子网要求 `service_access_sg` 必须允许来自 master 的 9443 端口入站，否则 EMR 控制平面无法完成集群初始化（master 向控制平面汇报状态走 9443）。

**解决**
补充两条规则：

```hcl
# master 出站 9443 → service_access
resource "aws_security_group_rule" "master_egress_to_service_access" {
  type                     = "egress"
  from_port                = 9443
  to_port                  = 9443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_master.id
  source_security_group_id = aws_security_group.emr_service_access.id
}

# service_access 入站 9443 ← master
resource "aws_security_group_rule" "service_access_ingress_from_master" {
  type                     = "ingress"
  from_port                = 9443
  to_port                  = 9443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.emr_service_access.id
  source_security_group_id = aws_security_group.emr_master.id
}
```

---

## 6. Bootstrap 脚本 wget 卡住（45 分钟超时）

**现象**
Bootstrap action 1 执行 `wget https://jdbc.postgresql.org/download/postgresql-42.7.3.jar`，挂起 45 分钟后超时失败。

**原因**
EMR 节点在私有子网，没有直接访问公网的路径（NAT 未启用，或 NAT 路由配置存在问题），wget 到公网地址直接超时。

**解决**
不走公网，改从 S3 下载。Terraform apply 时先把 jar 上传到 S3，bootstrap 脚本改用 `aws s3 cp`（走 S3 Gateway Endpoint，不走 NAT）：

```bash
# install_deps.sh.tftpl
sudo mkdir -p /usr/lib/spark/jars
sudo aws s3 cp s3://${etl_bucket}/bootstrap/postgresql-42.7.3.jar \
  /usr/lib/spark/jars/postgresql-42.7.3.jar
```

```hcl
# s3.tf — 上传 jar
resource "aws_s3_object" "jdbc_driver" {
  bucket = aws_s3_bucket.etl.id
  key    = "bootstrap/postgresql-42.7.3.jar"
  source = "${path.module}/../../../bootstrap/postgresql-42.7.3.jar"
}
```

---

## 7. Bootstrap 脚本 Permission denied 写入 /usr/lib/spark/jars

**错误**
```
aws s3 cp: Permission denied: /usr/lib/spark/jars/postgresql-42.7.3.jar
```

**原因**
`/usr/lib/spark/jars/` 目录在 bootstrap 阶段不存在，`aws s3 cp` 无法写入不存在的目录。

**解决**
在 `aws s3 cp` 之前加 `sudo mkdir -p`：

```bash
sudo mkdir -p /usr/lib/spark/jars
sudo aws s3 cp s3://.../postgresql-42.7.3.jar /usr/lib/spark/jars/
```

---

## 8. EMR VPC Endpoint 缺失导致 Bootstrap Action 2 失败

**错误**
Bootstrap action 2 报 "EMR internal error"，bootstrap action 1 成功，但 EMR 控制平面无法完成后续配置。

**原因**
EMR 控制平面通过 `com.amazonaws.region.elasticmapreduce` Interface Endpoint 与集群节点通信。全私有子网下没有这个 Endpoint，EMR 内部流量无法到达控制平面。

**解决**
在 VPC 模块里添加 EMR Interface Endpoint：

```hcl
resource "aws_vpc_endpoint" "emr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.elasticmapreduce"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}
```

---

## 9. RDS PostgreSQL 版本号写法错误

**错误**
```
InvalidParameterCombination: Cannot find version 15.7 for postgres
```

**原因**
`engine_version = "15.7"` 在某些区域不可用，AWS 不一定部署了每个 patch 版本。

**解决**
只写主版本号，让 AWS 自动选 patch：

```hcl
engine_version = "15"
```

---

## 10. Secrets Manager — AccessDeniedException（Secret 名称写错）

**错误**
```
AccessDeniedException: User is not authorized to access this secret
```

**原因**
IAM 策略里 `resources = [var.rds_secret_arn]`，Secret 的 ARN 对应的名称是 `emr-etl-dev/rds/ordersdb`，但脚本里传的 `--secret-name` 写成了 `emr-etl-dev/rds`（少了 `/ordersdb`）。

**解决**
对照 `terraform output rds_secret_name` 确认完整名称，传参时精确匹配：

```bash
--secret-name emr-etl-dev/rds/ordersdb
```

---

## 11. psql SCRAM 认证失败

**错误**
```
psql: SCRAM authentication requires libpq version 10 or above
```

**原因**
EMR 自带的 psql 版本太旧（libpq < 10），不支持 PostgreSQL 15 默认的 SCRAM-SHA-256 认证。

**解决**
卸载旧版，用 `amazon-linux-extras` 安装 postgresql14：

```bash
sudo yum remove -y postgresql
sudo amazon-linux-extras install -y postgresql14
```

> 不要用 `yum install postgresql15`，Amazon Linux 2 的 yum 仓库里 postgresql15 包可能不存在。

---

## 12. SSM 用户没有 boto3

**错误**
```
ModuleNotFoundError: No module named 'boto3'
```

**原因**
SSM 登录默认是 `ssm-user`，用的是系统 Python 环境，不含 boto3。EMR 的 Python 环境（含 boto3）归 `hadoop` 用户所有。

**解决**
登录后先切换到 hadoop 用户，再运行任何 Python/PySpark 脚本：

```bash
sudo su - hadoop
```

或者给系统 Python 单独安装：

```bash
sudo pip3 install boto3
```

---

## 13. spark-submit ClassNotFoundException: EmrFileSystem

**错误**
```
java.lang.ClassNotFoundException: org.apache.hadoop.fs.s3.EmrFileSystem
```

**原因**
EMR 的 EMRFS（EmrFileSystem）jar 路径通常由 `/etc/spark/conf/spark-defaults.conf` 注入 classpath，但当 `configurations_json` 自定义了 `spark-defaults` 分类时，EMR 可能不生成这个文件（只留 `.template`），导致 EMRFS jar 没有被自动加载。

**解决**
显式把 EMRFS jar 传给 `spark-submit`：

```bash
spark-submit \
  --jars /usr/lib/spark/jars/postgresql-42.7.3.jar,/usr/share/aws/emr/emrfs/lib/emrfs-hadoop-assembly-2.60.0.jar \
  --driver-class-path /usr/share/aws/emr/emrfs/lib/emrfs-hadoop-assembly-2.60.0.jar \
  your_script.py
```

**根因说明**
- 正常情况下 EMR 启动会把 EMRFS jar 路径写入 `spark.driver.extraClassPath` 和 `spark.executor.extraClassPath`
- 自定义 `configurations_json` 的 `spark-defaults` 分类干扰了这个写入过程
- 生产环境建议在 `configurations_json` 里直接把 EMRFS jar 路径加进去，或者直接显式传参，不依赖自动配置

---

## 14. 私有子网 EMR 的 /tmp 目录权限问题

**现象**
以 `ssm-user` 身份运行脚本，写入 `/home/hadoop/` 时报 Permission denied。

**原因**
SSM session 默认以 `ssm-user` 身份登录，`/home/hadoop/` 属于 hadoop 用户。

**解决**
所有 PySpark 相关操作都在切换到 hadoop 用户后进行；临时文件统一放 `/tmp/`，`/tmp/` 对所有用户可写。

---

## 15. Terraform perpetual diff — inline SG 规则与 aws_security_group_rule 混用

**现象**
每次 `terraform plan` 都显示同样的 egress 规则要被删除，apply 之后下次 plan 又出现，永远无法收敛。

**原因**
`aws_security_group` 里只要有任何 inline `ingress`/`egress` 块，Terraform 就认为自己"拥有"该 SG 该方向的**全部**规则。apply 时它会把不在 inline 块里的规则从 SG 移除。但同时存在的 `aws_security_group_rule` 资源又把这些规则加回来，下次 plan 就再次看到差异，循环往复。

**解决**
同一个 SG、同一个方向（ingress 或 egress），只能二选一：
- 全用 inline 块（简单场景）
- 全用 `aws_security_group_rule` 资源（跨 SG 引用、避免循环依赖时必须用）

本项目因为安全组之间互相引用（循环依赖问题 #1），必须用 `aws_security_group_rule`，所以把所有 inline `egress` 块都拆成独立资源：

```hcl
# 不要这样（inline 和独立规则混用）：
resource "aws_security_group" "emr_master" {
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group_rule" "master_egress_to_slave" { ... }  # 冲突！

# 改成这样（全部用独立规则）：
resource "aws_security_group" "emr_master" {
  # 不放任何 ingress/egress 块
}
resource "aws_security_group_rule" "master_egress_https" {
  type              = "egress"
  from_port         = 443
  ...
}
resource "aws_security_group_rule" "master_egress_to_slave" { ... }
```

---

## 16. Terraform perpetual diff — RDS parameter group apply_method

**现象**
每次 plan 都显示 `rds.force_ssl` 的 `apply_method` 从 `pending-reboot` 改成 `immediate`，apply 后下次 plan 又出现。

**原因**
`rds.force_ssl` 是 PostgreSQL 的 static 参数，必须重启才能生效。AWS 不管代码里写什么，都强制把 `apply_method` 存为 `pending-reboot`。Terraform 代码里不写 `apply_method` 时默认发送 `immediate`，每次都和 AWS 实际值不一致。

**解决**
代码里显式写 `apply_method = "pending-reboot"` 与 AWS 对齐：

```hcl
parameter {
  name         = "rds.force_ssl"
  value        = "1"
  apply_method = "pending-reboot"
}
```

---

## 快速参考：私有子网 EMR 必需的安全组端口

| 端口 | 方向 | 用途 |
|------|------|------|
| 8443 | service_access → master/slave | EMR 控制平面管理集群 |
| 9443 | master → service_access | master 向控制平面汇报状态 |
| 全部 | master ↔ slave | YARN / Spark 内部通信 |
| 5432 | master/slave → RDS | JDBC 连接 |
| 443  | master/slave → endpoints-sg | SSM、Secrets Manager、S3 |

## 快速参考：私有子网 EMR 必需的 VPC Endpoints

| Endpoint | 类型 | 用途 |
|----------|------|------|
| S3 Gateway | Gateway（免费）| Bootstrap 下载 jar、EMRFS 写 S3 |
| SSM | Interface | Session Manager 登录 |
| SSM Messages | Interface | Session Manager 登录 |
| EC2 Messages | Interface | Session Manager 登录 |
| Secrets Manager | Interface | 读取 RDS 凭证 |
| EMR | Interface | EMR 控制平面与集群通信 |
