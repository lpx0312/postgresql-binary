#!/bin/bash
set -euo pipefail

# ============================================================
# CI 编译脚本:构建基础镜像 → 构建编译镜像 → 提取 tarball
# ---------------------------------------------------------------------------
# 环境变量:
#   PGSQL_VERSION - PostgreSQL 版本号(必填,如 17.5)
#   ARCH          - 目标架构(必填,amd64 / arm64)
#   ZONE          - 可选,cn=国内源加速;空=官方源
#
# 编译基线固定为 glibc 2.17(CentOS 7),产物兼容所有 glibc >= 2.17 的系统。
# 基础镜像不推外部 registry,直接在 runner 本地构建
# (buildx gha 缓存加速,第二次构建几乎秒过)。
# 前提:runner 与目标镜像同架构 —— 由原生 runner 保证:
#   amd64 job 用 ubuntu-latest,arm64 job 用 ubuntu-24.04-arm
#
# 产物:output/postgresql-<ver>-linux-<arch>.tar.gz
# ============================================================

PGSQL_VERSION="${PGSQL_VERSION:?ERROR: 必须设置 PGSQL_VERSION(如 17.5)}"
ARCH="${ARCH:?ERROR: 必须设置 ARCH(amd64 或 arm64)}"
ZONE="${ZONE:-}"

case "$ARCH" in
    amd64|arm64) ;;
    *) echo "❌ 无效 ARCH: $ARCH(应为 amd64 或 arm64)"; exit 1 ;;
esac

BASE_TAG="pgsql-binary:base-glib-2.17"
BUILD_IMAGE_TAG="pgsql-binary-build:${PGSQL_VERSION}-${ARCH}"

echo "============================================"
echo "  编译 PostgreSQL 二进制 (glibc 2.17 基线)"
echo "============================================"
echo "  PostgreSQL 版本: ${PGSQL_VERSION}"
echo "  目标架构:    ${ARCH}"
echo "  基础镜像:    ${BASE_TAG}(本地构建)"
echo "============================================"

# ------------------------------------------------------------
# Step 1: 本地构建基础镜像(gha 缓存加速)
# ------------------------------------------------------------
echo ""
echo ">>> 构建基础镜像 ${BASE_TAG}..."
docker buildx build \
    --load \
    --build-arg "TARGETARCH=${ARCH}" \
    ${ZONE:+--build-arg "ZONE=${ZONE}"} \
    --cache-from type=gha \
    --cache-to type=gha,mode=max \
    -t "${BASE_TAG}" \
    -f "base/Dockerfile-glib2.17" \
    .

# ------------------------------------------------------------
# Step 2: 构建编译镜像(内含下载源码+编译+打包+冒烟测试)
# 用经典 docker build(default 驱动)而非 buildx:buildx 的 docker-container
# 驱动解析 FROM 时只查 registry,看不到上面 --load 进本地镜像仓库的
# 基础镜像;default 驱动直接用本地镜像仓库,无需推外部 registry。
# ------------------------------------------------------------
echo ""
echo ">>> 构建编译镜像并提取产物..."
DOCKER_BUILDKIT=1 docker build \
    --build-arg "BASE_SYSTEM_VERSION=${BASE_TAG}" \
    --build-arg "PGSQL_VERSION=${PGSQL_VERSION}" \
    --build-arg "TARGETARCH=${ARCH}" \
    -t "${BUILD_IMAGE_TAG}" \
    -f build/Dockerfile \
    build/

# ------------------------------------------------------------
# Step 3: 从镜像提取产物(docker create + docker cp)
# ------------------------------------------------------------
EXTRACT_CID="pgsql-extract-$$"
echo ""
echo ">>> 从镜像提取产物..."
docker create --name "${EXTRACT_CID}" "${BUILD_IMAGE_TAG}" /bin/true >/dev/null

mkdir -p output
docker cp "${EXTRACT_CID}:/root/output/." output/
docker rm -f "${EXTRACT_CID}" >/dev/null

# 只保留 tarball
find output/ ! -name '*.tar.gz' -type f -delete 2>/dev/null || true
find output/ -type d -empty -delete 2>/dev/null || true

# 最终校验
REAL_TARBALL="$(ls output/postgresql-${PGSQL_VERSION}-linux-${ARCH}.tar.gz 2>/dev/null | head -1 || true)"
if [ -z "${REAL_TARBALL}" ]; then
    echo "❌ 未能从镜像提取 postgresql-${PGSQL_VERSION}-linux-${ARCH}.tar.gz 产物"
    ls -la output/ || true
    exit 1
fi

echo ""
echo "============================================"
echo "  ✅ 编译完成!产物列表:"
echo "============================================"
ls -lh output/
echo "============================================"

# 清理编译镜像(腾出空间,避免 runner 磁盘爆;基础镜像保留供缓存复用)
docker rmi "${BUILD_IMAGE_TAG}" 2>/dev/null || true
