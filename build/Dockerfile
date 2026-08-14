# syntax=docker/dockerfile:1
###############################################################################
# PostgreSQL 编译镜像 —— 下载源码、编译、打包(glibc 2.17 基线,通用)
# ---------------------------------------------------------------------------
# 基于 base/Dockerfile-glib2.17 的基础镜像(已装好 devtoolset-11/10、
# patchelf、自编译 OpenSSL 1.1.1w)。
#
# 构建上下文:
#   postgresql-binary/build/
#   ├── Dockerfile
#   ├── pgsql-build-binary.sh
#   └── ci-build-binary.sh
#
# 构建示例(先构建好本地基础镜像 pgsql-binary:base-glib-2.17):
#   docker build -f build/Dockerfile \
#       --build-arg BASE_SYSTEM_VERSION=pgsql-binary:base-glib-2.17 \
#       --build-arg PGSQL_VERSION=17.5 \
#       --build-arg TARGETARCH=amd64 \
#       -t pgsql-binary-build:17.5-amd64 build/
#
# 产物位置(镜像内):/root/output/postgresql-<ver>-linux-<arch>.tar.gz
###############################################################################

# 基础镜像(本地构建,无需外部 registry)
ARG BASE_SYSTEM_VERSION=pgsql-binary:base-glib-2.17
FROM ${BASE_SYSTEM_VERSION}

WORKDIR /root

# 必填:PostgreSQL 版本号(如 17.5)
ARG PGSQL_VERSION
# 必填:目标架构(amd64 / arm64),CI 显式传入
ARG TARGETARCH
# 可选:下载代理(内网构建时可设)
ARG DOWNLOAD_PROXY=""

RUN test -n "$PGSQL_VERSION" || { echo "ERROR: 需要 --build-arg PGSQL_VERSION= 指定版本(如 17.5)"; exit 1; } && \
    test -n "$TARGETARCH" || { echo "ERROR: 需要 --build-arg TARGETARCH= 指定架构(amd64/arm64)"; exit 1; }

# 配置下载代理(若提供)。无条件先 touch 创建 proxy.sh,避免后续 source
# 一个不存在的文件 —— 在 set -e 下 source 不存在文件会让整个 RUN 退出。
RUN touch /etc/profile.d/proxy.sh && \
    if [ -n "$DOWNLOAD_PROXY" ]; then \
        echo "==> 使用下载代理: $DOWNLOAD_PROXY"; \
        echo "export http_proxy=$DOWNLOAD_PROXY"  >> /etc/profile.d/proxy.sh; \
        echo "export https_proxy=$DOWNLOAD_PROXY" >> /etc/profile.d/proxy.sh; \
        echo "export HTTP_PROXY=$DOWNLOAD_PROXY"  >> /etc/profile.d/proxy.sh; \
        echo "export HTTPS_PROXY=$DOWNLOAD_PROXY" >> /etc/profile.d/proxy.sh; \
    fi

# 拷贝编译+打包脚本
COPY pgsql-build-binary.sh /root/pgsql-build-binary.sh

# 编译 + 打包 + 兼容性检查 + 冒烟测试
ENV PGSQL_VERSION=${PGSQL_VERSION} \
    ARCH=${TARGETARCH}
RUN chmod +x /root/pgsql-build-binary.sh && \
    { [ -f /etc/profile.d/proxy.sh ] && source /etc/profile.d/proxy.sh 2>/dev/null || true; } && \
    bash /root/pgsql-build-binary.sh
