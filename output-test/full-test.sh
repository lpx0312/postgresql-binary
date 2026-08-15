#!/bin/bash
# PostgreSQL 二进制包全面测试:工具版本、依赖完整性、initdb、启停、SQL 读写、
# 扩展加载(contrib)、备份恢复(pg_dump/pg_restore)、认证
set -e
BASE=/tmp/pgsql-binary-test

# postgres 拒绝以 root 运行:root 调用时自动降权到普通用户重跑
if [ "$(id -u)" = 0 ]; then
    id pgtest >/dev/null 2>&1 || useradd -m -s /bin/bash pgtest
    mkdir -p "$BASE"
    chown -R pgtest "$BASE"
    exec su pgtest -s /bin/bash -c "bash $0"
fi

# 自动探测解压出的包目录(postgresql-<ver>-linux-<arch>)
PKG=$(ls -d "$BASE"/postgresql-*-linux-*/ | head -1)
[ -n "$PKG" ] || { echo "FAIL: 未找到 $BASE/postgresql-*-linux-*/ 目录"; exit 1; }
PGDATA=$BASE/data
SOCKDIR=$BASE/sock
PORT=15432
# psql/createdb/pg_dump 等客户端默认以 OS 用户名连库,统一用 postgres 超级用户
export PGUSER=postgres
cd "$PKG"

wait_up() {
    for i in $(seq 50); do
        bin/pg_isready -h "$SOCKDIR" -p "$PORT" -q && return 0
        sleep 0.2
    done
    echo "FAIL: 服务在 10 秒内未就绪"; return 1
}

echo "===== 1. 主要二进制版本 ====="
for b in postgres initdb pg_ctl psql pg_dump pg_dumpall pg_restore pg_basebackup pgbench pg_isready pg_controldata; do
    bin/$b --version
done

echo "===== 2. ldd 全部二进制,检查无缺失库 ====="
for b in bin/*; do
    if ldd "$b" 2>/dev/null | grep -q "not found"; then
        echo "FAIL: $b 有缺失库"; ldd "$b"; exit 1
    fi
done
echo "全部二进制依赖完整"

echo "===== 3. initdb 初始化 + 启动 ====="
rm -rf "$PGDATA" "$SOCKDIR"; mkdir -p "$SOCKDIR"
bin/initdb -D "$PGDATA" -U postgres -E UTF8 --locale=C -A trust
bin/pg_ctl -D "$PGDATA" -o "-p $PORT -k $SOCKDIR -c listen_addresses=''" -l "$BASE/pg1.log" -w start
wait_up
bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -c 'SELECT version();'

echo "===== 4. SQL 读写 + 重启恢复 ====="
bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -qc '
CREATE TABLE smoke(id serial primary key, val text, ts timestamp default now());
INSERT INTO smoke(val) VALUES ('"'"'hello'"'"'), ('"'"'world'"'"');'
V=$(bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -tAc 'SELECT count(*) FROM smoke')
[ "$V" = "2" ] || { echo "FAIL: 写入失败, count=$V"; exit 1; }
bin/pg_ctl -D "$PGDATA" -m fast stop
bin/pg_ctl -D "$PGDATA" -o "-p $PORT -k $SOCKDIR -c listen_addresses=''" -l "$BASE/pg2.log" -w start
wait_up
V=$(bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -tAc 'SELECT val FROM smoke WHERE id=1')
[ "$V" = "hello" ] || { echo "FAIL: 重启恢复失败, got: $V"; exit 1; }
echo "重启恢复 OK"

echo "===== 5. contrib 扩展加载 ====="
bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -qc 'CREATE EXTENSION pg_stat_statements;'
V=$(bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -tAc \
    "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'")
[ "$V" = "1" ] || { echo "FAIL: pg_stat_statements 扩展加载失败"; exit 1; }
echo "contrib 扩展加载 OK"

echo "===== 6. pg_dump/pg_restore 备份恢复 ====="
bin/createdb -h "$SOCKDIR" -p "$PORT" testdb
bin/psql -h "$SOCKDIR" -p "$PORT" -d testdb -qc 'CREATE TABLE t1(i int); INSERT INTO t1 SELECT generate_series(1,100);'
bin/pg_dump -h "$SOCKDIR" -p "$PORT" -Fc -d testdb -f "$BASE/testdb.dump"
bin/dropdb -h "$SOCKDIR" -p "$PORT" testdb
bin/createdb -h "$SOCKDIR" -p "$PORT" testdb
bin/pg_restore -h "$SOCKDIR" -p "$PORT" -d testdb "$BASE/testdb.dump"
V=$(bin/psql -h "$SOCKDIR" -p "$PORT" -d testdb -tAc 'SELECT count(*) FROM t1')
[ "$V" = "100" ] || { echo "FAIL: 备份恢复失败, count=$V"; exit 1; }
echo "pg_dump/pg_restore OK"

echo "===== 7. 密码认证(scram-sha-256) ====="
bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -qc "ALTER USER postgres PASSWORD 'test123';" 
bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -qc \
    "ALTER SYSTEM SET password_encryption='scram-sha-256'; SELECT pg_reload_conf();"
bin/psql -h "$SOCKDIR" -p "$PORT" -d postgres -qc \
    "CREATE ROLE testuser LOGIN PASSWORD 'test123';"
PGPASSWORD=test123 bin/psql -h "$SOCKDIR" -p "$PORT" -U testuser -d postgres -tAc 'SELECT 1;'
echo "scram-sha-256 认证 OK"

echo "===== 8. pgbench 压力测试 ====="
bin/pgbench -h "$SOCKDIR" -p "$PORT" -i -q testdb
bin/pgbench -h "$SOCKDIR" -p "$PORT" -c 4 -j 2 -t 100 -q testdb
echo "pgbench OK"

bin/pg_ctl -D "$PGDATA" -m fast stop
bin/pg_controldata "$PGDATA" | head -5

echo ""
echo "=========================================="
echo "  ALL FULL TESTS PASSED on $(hostname) [$(cat /etc/os-release | grep PRETTY_NAME | cut -d\" -f2)]"
echo "=========================================="
