# PostgreSQL 17.11 便携二进制 · 安装部署手册

> 产物来源：<https://github.com/lpx0312/postgresql-binary/releases/tag/v17.11>
> 本文以 **192.168.1.45（麒麟 V10，x86_64，glibc 2.28）单实例部署**为完整示例，步骤可原样复用到任何目标机。
> 本文档包含内网地址与测试密码，**不要提交到公开仓库**。

## 一、前提条件

| 项 | 要求 | 检查命令 |
| ---- | ---- | ---- |
| 架构 | x86_64 → `amd64` 包；aarch64 → `arm64` 包 | `uname -m` |
| glibc | ≥ 2.17（CentOS 7+、麒麟 V10、openEuler、Debian 9+、Ubuntu 16.04+ 均满足） | `ldd --version` |
| C 库类型 | 不能是 musl（Alpine 不支持） | `ldd --version` 输出含 `GNU libc` |
| 依赖安装 | **零依赖**，TLS/zlib 运行库都在包内 | —— |
| 端口 | 5432（或自定义）未被占用 | `ss -tlnp \| grep 5432` |

目标机无外网时，先在有网机器上下载好 tarball 再传上去（scp / U盘 / 跳板）。

## 二、获取产物并校验

```bash
# 有外网的机器上下载(以 amd64 为例)
curl -LO https://github.com/lpx0312/postgresql-binary/releases/download/v17.11/postgresql-17.11-linux-amd64.tar.gz
curl -LO https://github.com/lpx0312/postgresql-binary/releases/download/v17.11/postgresql-17.11.sha256sum.txt

# 传到目标机(示例:传到 /root/)
scp postgresql-17.11-linux-amd64.tar.gz root@192.168.1.45:/root/
```

目标机上校验（值以 sha256sum.txt 内为准）：

```bash
cd /root
sha256sum postgresql-17.11-linux-amd64.tar.gz
# 665072531ea148f5dbc119a4229c3f77bca21889fde6e61f0091b1453b3811bd
```

## 三、解压安装

```bash
tar -xzf /root/postgresql-17.11-linux-amd64.tar.gz -C /usr/local/
ln -sfn /usr/local/postgresql-17.11-linux-amd64 /usr/local/pgsql   # 版本无关的软链

# 验证可执行 + 依赖自包含
/usr/local/pgsql/bin/postgres --version
ldd /usr/local/pgsql/bin/postgres
```

**预期**：
- `postgres (PostgreSQL) 17.11`
- `ldd` 中 `libssl.so.1.1`、`libcrypto.so.1.1` 解析到 `/usr/local/pgsql/bin/../lib/`（包内 RPATH 生效），其余仅 glibc 系 / libz —— 无 `not found` 即可。

## 四、创建运行用户与目录

postgres 拒绝以 root 运行，必须专用用户：

```bash
id postgres 2>/dev/null || useradd -m postgres
mkdir -p /home/postgres/pgdata
chown -R postgres:postgres /home/postgres/pgdata
```

## 五、初始化集群（initdb）

```bash
su - postgres
/usr/local/pgsql/bin/initdb -D /home/postgres/pgdata -E UTF8 --locale=C -A trust
```

**预期**：末尾输出 `Success. You can now start the database server using: ...`；默认时区会自动识别（本例 `Asia/Shanghai`）。

说明：
- `-A trust`：本地 socket 免密（initdb 后再按需收紧），生产建议 `-A scram-sha-256` 全程密码认证；
- `--locale=C` 兼容性最好；需要中文排序规则可用 `--locale=zh_CN.UTF-8`（要求系统已生成该 locale）。

## 六、配置

### postgresql.conf —— 监听

```bash
cd /home/postgres/pgdata
sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" postgresql.conf
grep -E "^listen_addresses|^port" postgresql.conf   # port 默认 5432,按需修改
```

### pg_hba.conf —— 放行远程网段

追加规则（按实际客户端网段；scram-sha-256 为密码认证）：

```bash
echo 'host    all             all             192.168.1.0/24            scram-sha-256' >> pg_hba.conf
echo 'host    all             all             192.168.0.0/24            scram-sha-256' >> pg_hba.conf
```

测试环境想全网段放行：`echo 'host all all 0.0.0.0/0 scram-sha-256' >> pg_hba.conf`

## 七、启动并验证

```bash
su - postgres
/usr/local/pgsql/bin/pg_ctl -D /home/postgres/pgdata -l /home/postgres/pgdata/server.log -w start

# 设置超级用户密码(远程 scram 连接用)
/usr/local/pgsql/bin/psql -c "ALTER USER postgres PASSWORD 'PgTest#2026';"

# 三项验证
/usr/local/pgsql/bin/psql -tAc 'SELECT version();'      # PostgreSQL 17.11 ...
/usr/local/pgsql/bin/pg_isready -h 127.0.0.1 -p 5432    # accepting connections
exit
ss -tlnp | grep 5432                                     # 0.0.0.0:5432 LISTEN
```

远程连接串：`postgresql://postgres:PgTest#2026@192.168.1.45:5432/postgres`

## 八、收尾（可选）

### 1. 环境变量

```bash
su - postgres
echo 'export PATH=/usr/local/pgsql/bin:$PATH' >> ~/.bashrc
```

### 2. systemd 开机自启（root 执行）

`/etc/systemd/system/postgresql.service`：

```ini
[Unit]
Description=PostgreSQL 17.11 (portable binary)
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
Environment=PGDATA=/home/postgres/pgdata
ExecStart=/usr/local/pgsql/bin/pg_ctl -D ${PGDATA} -l ${PGDATA}/server.log start
ExecStop=/usr/local/pgsql/bin/pg_ctl -D ${PGDATA} -m fast stop
ExecReload=/usr/local/pgsql/bin/pg_ctl -D ${PGDATA} reload
TimeoutSec=120
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now postgresql
systemctl status postgresql        # active (running)
```

> 注意：配了 systemd 就不要再手动 `pg_ctl start/stop`，统一用 `systemctl`，避免双管理打架。

### 3. 防火墙放行（麒麟/CentOS）

```bash
firewall-cmd --add-port=5432/tcp --permanent && firewall-cmd --reload
```

## 九、卸载 / 清理

```bash
su - postgres -c "/usr/local/pgsql/bin/pg_ctl -D /home/postgres/pgdata -m fast stop"
systemctl disable --now postgresql 2>/dev/null; rm -f /etc/systemd/system/postgresql.service
rm -f  /usr/local/pgsql
rm -rf /usr/local/postgresql-17.11-linux-amd64 /home/postgres /root/postgresql-17.11-linux-amd64.tar.gz
userdel -r postgres 2>/dev/null
```

---

## 附：本次 192.168.1.45 实装记录（速查）

| 项 | 值 |
| ---- | ---- |
| 安装目录 | `/usr/local/postgresql-17.11-linux-amd64`（软链 `/usr/local/pgsql`） |
| 运行用户 / 数据目录 | `postgres` / `/home/postgres/pgdata` |
| 日志 | `/home/postgres/pgdata/server.log` |
| 监听 / 网段放行 | `0.0.0.0:5432`；`192.168.1.0/24`、`192.168.0.0/24` |
| 密码 / 自启 | `postgres / PgTest#2026`；未配 systemd（手动 pg_ctl 管理） |
| 装机验证 | sha256 通过、ldd 自包含、initdb 成功、scram 远程登录 OK、`pg_stat_statements` 可用 |

安装完成后，按 [`manual-test-guide.md`](./manual-test-guide.md) 执行手动验证。
