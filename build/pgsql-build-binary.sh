#!/bin/bash
set -euo pipefail

# ============================================================
# PostgreSQL 编译 + 打包脚本(在编译镜像内执行)
# ---------------------------------------------------------------------------
# 环境变量(由 build/Dockerfile 的 ARG 注入):
#   PGSQL_VERSION - PostgreSQL 版本号(必填,如 17.5)
#   ARCH          - 目标架构(必填,amd64 / arm64),只用于产物目录/文件名
#
# 编译基线:glibc 2.17(CentOS 7),产物可在所有 glibc >= 2.17 的系统上运行
# (CentOS 7/8、Rocky、Debian、Ubuntu、kylin v10、openEuler 等)。
#
# 产物:/root/output/postgresql-<ver>-linux-<arch>.tar.gz
#   postgresql-<ver>-linux-<arch>/
#   ├── bin/     postgres initdb pg_ctl psql pg_dump ... (全部客户端/服务端工具)
#   ├── lib/     libssl.so.1.1 libcrypto.so.1.1(TLS 运行时,自带,免装)
#   │            及 *.so 内置模块(上游默认直接装 lib/,无 lib/postgresql 子目录)
#   └── share/   时区数据、扩展 SQL、sample 等
# ============================================================

PGSQL_VERSION="${PGSQL_VERSION:?ERROR: 必须设置 PGSQL_VERSION}"
ARCH="${ARCH:?ERROR: 必须设置 ARCH(amd64 或 arm64)}"

case "$ARCH" in
    amd64|arm64) ;;
    *) echo "❌ 无效 ARCH: $ARCH(应为 amd64 或 arm64)"; exit 1 ;;
esac

# 启用 devtoolset(amd64=11 / arm64=10,基础镜像已建统一软链 /opt/rh/devtoolset)
# set -u 下 devtoolset 的 enable 脚本引用未定义变量会报 unbound variable,先设空默认值
export MANPATH="${MANPATH:-}" PERL5LIB="${PERL5LIB:-}" INFOPATH="${INFOPATH:-}"
if [ -f /opt/rh/devtoolset/enable ]; then source /opt/rh/devtoolset/enable; fi

echo "============================================"
echo "  编译 PostgreSQL ${PGSQL_VERSION} (glibc 2.17, ${ARCH})"
echo "  gcc: $(gcc --version | head -1)"
echo "  glibc: $(ldd --version | head -1)"
echo "  openssl: $(openssl version)"
echo "============================================"

# 预检:configure 通过 pkg-config 探测 OpenSSL(基础镜像已装 openssl 1.1.1)
if ! pkg-config --modversion openssl >/dev/null 2>&1; then
    echo "❌ pkg-config 探测不到 openssl,检查基础镜像的 PKG_CONFIG_PATH 设置"
    exit 1
fi
echo "pkg-config openssl: $(pkg-config --modversion openssl)"

# OpenSSL 1.1.1 装在 /usr/local/openssl-1.1(非系统默认路径),PG 的 configure
# 探测 -lcrypto 时不会用 pkg-config 的链接参数,必须显式传头文件/库路径
OPENSSL_PREFIX="$(pkg-config --variable=prefix openssl)"
OPENSSL_LIBDIR="$(pkg-config --libs-only-L openssl | tr -d ' ' | sed 's/^-L//')"
echo "OPENSSL_PREFIX=${OPENSSL_PREFIX} OPENSSL_LIBDIR=${OPENSSL_LIBDIR}"

WORKDIR=/root/build
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

# ------------------------------------------------------------
# 下载 PostgreSQL 源码(官方源优先,GitHub 兜底)
# ------------------------------------------------------------
SRC_TARBALL="postgresql-${PGSQL_VERSION}.tar.gz"
if curl -fsSL --retry 5 --retry-delay 10 -o "${SRC_TARBALL}" \
        "https://ftp.postgresql.org/pub/source/v${PGSQL_VERSION}/${SRC_TARBALL}"; then
    echo "==> 已从 ftp.postgresql.org 下载源码"
else
    echo "==> ftp.postgresql.org 失败,改用 GitHub 兜底"
    curl -fsSL --retry 5 --retry-delay 10 -o "${SRC_TARBALL}" \
        "https://github.com/postgres/postgres/archive/refs/tags/REL_${PGSQL_VERSION//./_}.tar.gz"
fi

tar xzf "${SRC_TARBALL}"
rm -f "${SRC_TARBALL}"
SRC_DIR="postgresql-${PGSQL_VERSION}"
[ -d "${SRC_DIR}" ] || SRC_DIR="postgres-REL_${PGSQL_VERSION//./_}"
[ -d "${SRC_DIR}" ] || { echo "❌ 解压后未找到源码目录"; ls -la; exit 1; }
cd "${SRC_DIR}"

# ------------------------------------------------------------
# 编译(--prefix 直接指向暂存目录,make install 一步到位)
#   --with-openssl      TLS 支持(基础镜像的 OpenSSL 1.1.1,pkg-config 探测)
#   --without-readline  免 readline/ncurses 依赖(交互行编辑,非必需)
#   --without-icu       免 ICU 依赖(CentOS 7 的 ICU 太老,PG16+ 默认开启必须显式关)
#   --without-lz4/--without-zstd  免可选压缩库依赖
#   --disable-nls       免 gettext 依赖
# ------------------------------------------------------------
PKG_NAME="postgresql-${PGSQL_VERSION}-linux-${ARCH}"
STAGE="/root/output/${PKG_NAME}"

CPPFLAGS="-I${OPENSSL_PREFIX}/include" \
LDFLAGS="-L${OPENSSL_LIBDIR}" \
./configure \
    --prefix="${STAGE}" \
    --with-openssl \
    --with-zlib \
    --without-readline \
    --without-icu \
    --without-lz4 \
    --without-zstd \
    --disable-nls

make -j"$(nproc)"
make install
# contrib 扩展(pg_stat_statements、postgres_fdw 等,运维常用)
make -C contrib install

# ------------------------------------------------------------
# strip 瘦身 + 收集 TLS 运行库
# ------------------------------------------------------------
strip "${STAGE}"/bin/* || true
# 上游 PG 默认把内置模块直接装 lib/(无 lib/postgresql 子目录,那是 Debian 布局)
find "${STAGE}/lib" -maxdepth 1 -name '*.so' -exec strip {} \; || true

# 非 glibc 的动态依赖(libssl/libcrypto/libz)打进 lib/,目标机无需安装。
# 注意:PG 编译时默认给二进制加了指向 $prefix/lib 的绝对 RPATH,ldd 会把
# libpq.so.5 等解析到暂存目录内 —— 已在包内的库跳过,避免 cp 自己到自己报错
for bin in "${STAGE}"/bin/*; do
    ldd "${bin}" | awk '/=> \// {print $3}'
done | sort -u | grep -Ev '/lib(64)?/(ld-linux|libc|libm|libpthread|libdl|librt|libgcc_s|libstdc)' | \
    while read -r so; do
        case "$so" in "${STAGE}"*) continue ;; esac
        echo "==> 打包运行库: ${so}"
        cp -L "${so}" "${STAGE}/lib/"
    done

# RPATH 指向包内 lib/,解压即用,不依赖系统 openssl。
# bin/ 下的二进制引用 ../lib;lib/ 内的模块与 TLS 库同目录,用 $ORIGIN
patchelf --set-rpath '$ORIGIN/../lib' "${STAGE}"/bin/*
find "${STAGE}/lib" -maxdepth 1 -name '*.so' -exec patchelf --set-rpath '$ORIGIN' {} \;

# ------------------------------------------------------------
# 兼容性自检:二进制引用的最高 GLIBC 符号版本必须 <= 2.17
# ------------------------------------------------------------
MAX_GLIBC=$(objdump -T "${STAGE}/bin/postgres" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
echo "==> 二进制要求的最高 GLIBC 符号版本: ${MAX_GLIBC}"
if [ "${MAX_GLIBC}" \> "GLIBC_2.17" ]; then
    echo "❌ 兼容性检查失败: ${MAX_GLIBC} > GLIBC_2.17,产物无法在 CentOS 7 上运行"
    exit 1
fi

# ------------------------------------------------------------
# 冒烟测试(在编译容器内验证能初始化集群并跑 SQL)
# postgres 拒绝以 root 运行,先用非特权用户执行
# ------------------------------------------------------------
"${STAGE}/bin/postgres" --version
"${STAGE}/bin/psql" --version

id pgtest >/dev/null 2>&1 || useradd -m pgtest
# 数据目录由 root 预建并授权(initdb 接受已存在、属主正确、700 的空目录),
# 避免构建容器内 /tmp 权限不确定导致 pgtest 建目录失败
PGDATA=/tmp/pg-smoke
rm -rf "${PGDATA}"
install -d -o pgtest -g pgtest -m 700 "${PGDATA}"
chown -R pgtest "${STAGE}"
# CentOS 的 /root 默认 700,pgtest 无法穿透访问暂存目录,放开穿越权限(仅 +x,不可列目录)
chmod o+x /root
# 通过 stdin heredoc 喂给 su,避免 su -c 双引号里的嵌套引号转义地狱
su pgtest -s /bin/bash <<EOS
set -e
${STAGE}/bin/initdb -D ${PGDATA} -E UTF8 --locale=C -A trust >/dev/null
${STAGE}/bin/pg_ctl -D ${PGDATA} -l ${PGDATA}/logfile -o "-k ${PGDATA}" -w start
${STAGE}/bin/psql -h ${PGDATA} -d postgres -c 'SELECT version();'
${STAGE}/bin/psql -h ${PGDATA} -d postgres -c "CREATE TABLE smoke(id int, val text); INSERT INTO smoke VALUES (1, 'ok');"
V=\$(${STAGE}/bin/psql -h ${PGDATA} -d postgres -tAc 'SELECT val FROM smoke WHERE id=1')
[ "\$V" = "ok" ] || { echo 'smoke test rw FAILED'; exit 1; }
${STAGE}/bin/pg_ctl -D ${PGDATA} -m fast stop
echo 'smoke test PASSED'
EOS
rm -rf "${PGDATA}"

# ------------------------------------------------------------
# 打 tar.gz
# ------------------------------------------------------------
cd /root/output
TARBALL="${PKG_NAME}.tar.gz"
tar czf "${TARBALL}" "${PKG_NAME}"
rm -rf "${STAGE}"
ls -lh "${TARBALL}"
echo ""
echo "============================================"
echo "  ✅ PostgreSQL ${PGSQL_VERSION} 编译打包完成"
echo "============================================"
# head 读满即关管道,tar 会收 SIGPIPE(141),pipefail 下需容忍
tar tzf "${TARBALL}" | head -30 || true
