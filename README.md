# EMR ETL 数据抽取项目

RDS PostgreSQL → EMR (PySpark) → S3 (Parquet) 完整 ETL 流水线，全程私有子网，无需 SSH。

## 架构

```
┌─────────────────────────────────────────────────────────────────┐
│                      AWS VPC (10.0.0.0/16)                      │
│                                                                  │
│  ┌─────────────────┐      ┌──────────────────────────────────┐  │
│  │  Public Subnet  │      │        Private Subnet            │  │
│  │                 │      │                                  │  │
│  │  NAT Gateway    │      │   ┌────────────┐                 │  │
│  │                 │      │   │ EMR Master │ ← SSM 登录      │  │
│  │  Internet GW    │      │   │ (m4.large) │                 │  │
│  └─────────────────┘      │   └─────┬──────┘                 │  │
│                            │         │ YARN/Spark             │  │
│                            │   ┌─────┴──────┐                │  │
│                            │   │  EMR Core  │                │  │
│                            │   │ (m4.large) │                │  │
│                            │   └─────┬──────┘                │  │
│                            │         │ JDBC :5432             │  │
│                            │   ┌─────┴──────┐                │  │
│                            │   │    RDS     │                 │  │
│                            │   │ PostgreSQL │                 │  │
│                            │   │(db.t3.micro│                 │  │
│                            │   └────────────┘                │  │
│                            └──────────────────────────────────┘  │
│                                                                  │
│  VPC Endpoints（私有子网直连，不走公网）                          │
│  ┌──────────┐ ┌──────────────┐ ┌──────────────┐ ┌───────────┐   │
│  │   SSM    │ │ SSMMessages  │ │ EC2Messages  │ │  Secrets  │   │
│  └──────────┘ └──────────────┘ └──────────────┘ │  Manager  │   │
│  ┌──────────┐ ┌──────────────┐                   └───────────┘   │
│  │  S3 GW   │ │     EMR      │  (EMR Interface Endpoint)         │
│  └──────────┘ └──────────────┘                                   │
└─────────────────────────────────────────────────────────────────┘
```

## 安全组设计

```
emr-service-sg    出站: 8443 → emr-master-sg   (EMR 控制平面心跳)
                  出站: 8443 → emr-slave-sg

emr-master-sg     入站: 8443 ← emr-service-sg
                  入站: all  ← emr-slave-sg
                  出站: 9443 → emr-service-sg   (master 回报状态)
                  出站: all  → emr-slave-sg
                  出站: 5432 → rds-sg
                  出站: 443  → endpoints-sg

emr-slave-sg      入站: 8443 ← emr-service-sg
                  入站: all  ← emr-master-sg
                  出站: all  → emr-master-sg
                  出站: 5432 → rds-sg
                  出站: 443  → endpoints-sg

rds-sg            入站: 5432 ← emr-master-sg
                  入站: 5432 ← emr-slave-sg

endpoints-sg      入站: 443 (来自 VPC CIDR 10.0.0.0/16)
```

## 目录结构

```
11-emr-extract-demo/
├── terraform/
│   ├── environments/dev/    # 根模块：变量、S3、安全组、outputs
│   └── modules/
│       ├── vpc/             # VPC、子网、路由、NAT、VPC Endpoints
│       ├── emr/             # EMR 集群
│       ├── rds/             # RDS PostgreSQL
│       ├── iam/             # Service Role、EC2 Instance Profile
│       └── secrets/         # Secrets Manager（RDS 凭证）
├── bootstrap/
│   ├── install_deps.sh.tftpl   # Bootstrap 脚本模板（下载 JDBC jar）
│   └── postgresql-42.7.3.jar   # JDBC 驱动（本地，terraform 上传到 S3）
├── pyspark/
│   ├── emr_extract.py          # 主 ETL 脚本（RDS → Parquet → S3）
│   └── spark_sql_queries.py    # SparkSQL 演示脚本（6 个查询）
└── sql/
    ├── 01_create_table.sql     # 建表（ecommerce.orders）
    └── 02_seed_data.sql        # 灌数据（1000 行）
```

---

## 完整操作流程

### Step 1 — 部署基础设施

```bash
cd terraform/environments/dev

terraform init
terraform plan
terraform apply
```

apply 完成后查看关键 outputs：

```bash
terraform output                   # 看全部
terraform output etl_bucket        # S3 bucket 名
terraform output rds_secret_name   # Secret 名称
terraform output ssm_login_command # SSM 登录命令（含真实 instance-id）
terraform output spark_submit_command
```

> apply 到 EMR 集群大约需要 10–15 分钟。

---

### Step 2 — 上传脚本和 SQL 到 S3

在本机执行（替换 `<bucket>` 为 `terraform output -raw etl_bucket` 的输出）：

```bash
BUCKET=$(cd terraform/environments/dev && terraform output -raw etl_bucket)

# PySpark 脚本
aws s3 cp pyspark/emr_extract.py       s3://$BUCKET/scripts/emr_extract.py
aws s3 cp pyspark/spark_sql_queries.py s3://$BUCKET/scripts/spark_sql_queries.py

# SQL 文件
aws s3 cp sql/01_create_table.sql s3://$BUCKET/sql/01_create_table.sql
aws s3 cp sql/02_seed_data.sql    s3://$BUCKET/sql/02_seed_data.sql
```

> Bootstrap 脚本和 JDBC jar 由 `terraform apply` 自动上传，无需手动处理。

---

### Step 3 — 登录 EMR Primary Node（SSM）

```bash
# 方法一：直接用 terraform output 生成的命令
$(cd terraform/environments/dev && terraform output -raw ssm_login_command)

# 方法二：手动拼
aws ssm start-session \
  --target $(aws emr list-instances \
    --cluster-id <cluster-id> \
    --instance-group-types MASTER \
    --query 'Instances[0].Ec2InstanceId' \
    --output text) \
  --region ap-southeast-2
```

登录后切换到 hadoop 用户：

```bash
sudo su - hadoop
```

---

### Step 4 — 初始化 RDS 数据库

在 EMR primary node 上执行：

```bash
# 1. 读取 RDS 凭证
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id emr-etl-dev/rds/ordersdb \
  --query SecretString --output text \
  --region ap-southeast-2)

DB_HOST=$(echo $SECRET | python3 -c "import json,sys; print(json.load(sys.stdin)['host'])")
DB_USER=$(echo $SECRET | python3 -c "import json,sys; print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo $SECRET | python3 -c "import json,sys; print(json.load(sys.stdin)['password'])")
DB_NAME=$(echo $SECRET | python3 -c "import json,sys; print(json.load(sys.stdin)['dbname'])")

# 2. 安装 psql（EMR 默认没有）
sudo amazon-linux-extras install -y postgresql14

# 3. 下载 SQL 文件
ETL_BUCKET=$(aws s3 ls | grep emr-etl-dev-etl | awk '{print $3}')
aws s3 cp s3://$ETL_BUCKET/sql/01_create_table.sql /tmp/
aws s3 cp s3://$ETL_BUCKET/sql/02_seed_data.sql    /tmp/

# 4. 建表 + 灌数据
PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f /tmp/01_create_table.sql
PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f /tmp/02_seed_data.sql
```

---

### Step 5 — 运行 PySpark ETL 作业

在 EMR primary node（hadoop 用户）上执行：

```bash
ETL_BUCKET=$(aws s3 ls | grep emr-etl-dev-etl | awk '{print $3}')

# 下载脚本
aws s3 cp s3://$ETL_BUCKET/scripts/emr_extract.py /tmp/emr_extract.py

# 运行 spark-submit
spark-submit \
  --jars /usr/lib/spark/jars/postgresql-42.7.3.jar,/usr/share/aws/emr/emrfs/lib/emrfs-hadoop-assembly-2.60.0.jar \
  --driver-class-path /usr/share/aws/emr/emrfs/lib/emrfs-hadoop-assembly-2.60.0.jar \
  /tmp/emr_extract.py \
  --secret-name emr-etl-dev/rds/ordersdb \
  --output-path s3://$ETL_BUCKET/output/orders/ \
  --region ap-southeast-2
```

作业成功后，Parquet 文件写入 `s3://<bucket>/output/orders/`。

---

### Step 6 — 运行 SparkSQL 演示

```bash
aws s3 cp s3://$ETL_BUCKET/scripts/spark_sql_queries.py /tmp/spark_sql_queries.py

spark-submit \
  --jars /usr/lib/spark/jars/postgresql-42.7.3.jar,/usr/share/aws/emr/emrfs/lib/emrfs-hadoop-assembly-2.60.0.jar \
  --driver-class-path /usr/share/aws/emr/emrfs/lib/emrfs-hadoop-assembly-2.60.0.jar \
  /tmp/spark_sql_queries.py \
  --secret-name emr-etl-dev/rds/ordersdb \
  --region ap-southeast-2
```

包含 6 个查询：行数统计、状态分组收入、月度趋势、JSONB 解析、新老客户对比、窗口函数累计。

---

### Step 7 — 验证输出

```bash
# 查看 S3 上的 Parquet 文件
aws s3 ls s3://$ETL_BUCKET/output/orders/ --recursive

# 用 Spark 快速验证
pyspark --jars /usr/lib/spark/jars/postgresql-42.7.3.jar
# >>> spark.read.parquet("s3://$ETL_BUCKET/output/orders/").show(5)
```

---

### Step 8 — 销毁资源

```bash
cd terraform/environments/dev
terraform destroy
```

> EMR 集群配置了 `idle_timeout = 3600`，空闲 1 小时自动关闭。`terraform destroy` 前无需手动终止集群。

---

## 关键设计说明

| 设计点 | 方案 | 原因 |
|--------|------|------|
| 登录方式 | SSM Session Manager | 无需 key pair，无需开放 22 端口 |
| 网络 | 全私有子网 + VPC Endpoints | 流量不出 AWS 网络，安全且免公网费用 |
| 凭证管理 | Secrets Manager | 不在代码/环境变量中硬编码密码 |
| JDBC 驱动 | Bootstrap 从 S3 下载 | EMR 自带的 `/usr/lib/spark/jars/` 不含 PostgreSQL 驱动 |
| EMRFS | 显式传入 `--jars` | 自定义 `configurations_json` 可能导致 `spark-defaults.conf` 未生成，EMRFS 未自动加载 |
| 实例类型 | m4.large | ap-southeast-2 新账号 m5 系列存在容量限制 |
| 自动关机 | `auto_termination_policy 3600s` | 防止忘关集群产生费用 |
