# PostgreSQL 17.11 便携二进制 · 手动测试手册

> 实例：192.168.1.45（麒麟 V10，x86_64，glibc 2.28）
> 二进制来源：<https://github.com/lpx0312/postgresql-binary/releases/tag/v17.11>（glibc 2.17 基线，sha256 校验通过）
> 本文档包含内网地址与测试密码，**不要提交到公开仓库**。

## 一、实例信息

| 项 | 值 |
| ---- | ---- |
| 安装目录 | `/usr/local/postgresql-17.11-linux-amd64`（软链 `/usr/local/pgsql`） |
| 运行用户 | `postgres` |
| 数据目录 | `/home/postgres/pgdata` |
| 服务日志 | `/home/postgres/pgdata/server.log` |
| 监听 | `0.0.0.0:5432` |
| 认证 | 本地 trust；`192.168.1.0/24`、`192.168.0.0/24` 网段 scram-sha-256 |
| 超级用户 | `postgres / PgTest#2026` |

远程连接串（Navicat / DBeaver 直接可用）：

```
postgresql://postgres:PgTest#2026@192.168.1.45:5432/postgres
```

## 二、测试前准备

```bash
ssh root@192.168.1.45
su - postgres
export PATH=/usr/local/pgsql/bin:$PATH    # 建议追加到 ~/.bashrc
```

---

## ① 服务管理（pg_ctl）

| 操作 | 命令 | 预期 |
| ---- | ---- | ---- |
| 查状态 | `pg_ctl -D ~/pgdata status` | 输出 pid 与 "server is running" |
| 端口探测 | `pg_isready -h 127.0.0.1 -p 5432` | `accepting connections` |
| 启动 | `pg_ctl -D ~/pgdata -l ~/pgdata/server.log start` | `server started` |
| 停止 | `pg_ctl -D ~/pgdata stop` | `server stopped`（默认 fast 模式） |
| 重启 | `pg_ctl -D ~/pgdata restart` | 先停后起 |
| 重载配置 | `pg_ctl -D ~/pgdata reload` | `server signaled`（免重启项生效） |

## ② 基础 SQL 与事务

```bash
psql                                          # 本地 socket 直连(trust)
psql -h 192.168.1.45 -U postgres -d postgres  # TCP 密码连接
```

```sql
CREATE DATABASE testdb;
\c testdb
CREATE TABLE t1(id serial PRIMARY KEY, info text, ts timestamptz DEFAULT now());
INSERT INTO t1(info) VALUES ('hello'),('world');
SELECT * FROM t1 ORDER BY id;

-- 事务回滚验证:UPDATE 后 ROLLUP,数据应不变
BEGIN;
UPDATE t1 SET info='changed' WHERE id=1;
ROLLBACK;
SELECT * FROM t1 WHERE id=1;   -- info 应仍为 hello
```

**预期**：建库建表、CRUD 均成功；回滚后 `id=1` 的 `info` 仍为 `hello`。

## ③ 持久性（重启后数据不丢）

```bash
psql -d testdb -c "INSERT INTO t1(info) VALUES ('before-restart');"
pg_ctl -D ~/pgdata restart
psql -d testdb -tAc "SELECT count(*) FROM t1;"
```

**预期**：重启后行数包含 `before-restart` 那条（累计 4 行）。

## ④ 扩展（contrib 完整性）

```sql
\c testdb
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pgcrypto;
SELECT gen_random_uuid();                 -- 应返回一个 UUID
SELECT digest('abc','sha256');            -- 应返回 16 进制摘要
\dx                                      -- 列出已装扩展
```

**预期**：扩展创建无报错；`pg_stat_statements`、`pgcrypto` 出现在 `\dx` 列表。

## ⑤ 逻辑备份 / 恢复

```bash
pg_dump -Fc -d testdb -f /tmp/testdb.dump     # 自定义格式备份
dropdb testdb && createdb testdb
pg_restore -d testdb /tmp/testdb.dump         # 恢复
psql -d testdb -tAc "SELECT count(*) FROM t1;"  # 行数与备份前一致
pg_dumpall --globals-only | head -20            # 全局对象(角色/表空间)备份
```

**预期**：删除重建后数据完整恢复；`pg_dumpall` 能导出角色定义。

## ⑥ 物理备份（基础备份）

```bash
pg_basebackup -D /tmp/basebak -Fp -Xs -P -h 127.0.0.1 -U postgres
ls /tmp/basebak            # 应有 base/ pg_wal/ postgresql.conf 等
rm -rf /tmp/basebak
```

**预期**：备份进度到 100%，目录结构完整。

## ⑦ 性能基准（pgbench）

```bash
createdb benchdb
pgbench -i -s 10 benchdb             # 初始化 10 万行
pgbench -c 8 -j 4 -T 30 benchdb      # 8 并发跑 30 秒
dropdb benchdb
```

**预期**：输出 TPS / latency 统计，无报错（数值随机器而异）。

## ⑧ 远程连接（从工作电脑）

用 Navicat / DBeaver 连接：

| 项 | 值 |
| ---- | ---- |
| 主机 | `192.168.1.45` |
| 端口 | `5432` |
| 用户/密码 | `postgres / PgTest#2026` |
| 数据库 | `postgres` |

**预期**：能登录并执行 `SELECT version();`，返回 `PostgreSQL 17.11 ... gcc (GCC) 11.2.1 ...`。

## ⑨ 日志与异常排查

```bash
tail -50 ~/pgdata/server.log              # 运行日志
grep -i error ~/pgdata/server.log | tail  # 错误速查
```

---

## 三、常见问题

### 1. 远程连接报 `no pg_hba.conf entry for host "x.x.x.x" ...`

客户端网段没在 `pg_hba.conf` 放行。例如从 `192.168.0.x` 连接被拒，追加对应网段并重载：

```bash
echo 'host all all 192.168.0.0/24 scram-sha-256' >> /home/postgres/pgdata/pg_hba.conf
su - postgres -c "/usr/local/pgsql/bin/pg_ctl -D /home/postgres/pgdata reload"
```

测试环境想全网段放行（仍有密码认证）：

```bash
echo 'host all all 0.0.0.0/0 scram-sha-256' >> /home/postgres/pgdata/pg_hba.conf
su - postgres -c "/usr/local/pgsql/bin/pg_ctl -D /home/postgres/pgdata reload"
```

> 验证规则是否加载成功：
> `psql -tAc "SELECT line_number,type,database,user_name,address,error FROM pg_hba_file_rules ORDER BY line_number"`
> `error` 列为空即正常。

### 2. `postgres: could not be run as root`

postgres 拒绝 root 运行。所有服务端命令（initdb / pg_ctl / postgres）都切到 `postgres` 用户执行：`su - postgres`。

### 3. 连接卡住 / 超时

依次检查：`pg_isready`（库活着吗）→ `ss -tlnp | grep 5432`（监听吗）→ 防火墙（麒麟：`systemctl status firewalld`）。

## 四、说明

- 实例由 `pg_ctl` 手动管理，**未配置 systemd 开机自启**；需要的话补一个 unit 即可。
- 测试完成后若要清理：`pg_ctl -D ~/pgdata stop`，然后删除 `/usr/local/pgsql`、`/usr/local/postgresql-17.11-linux-amd64`、`/home/postgres`、`/root/postgresql-17.11-linux-amd64.tar.gz`。
