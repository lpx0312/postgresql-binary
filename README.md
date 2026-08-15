# postgresql-binary

使用 GitHub Actions 编译 PostgreSQL 官方源码，产出便携式二进制离线包并发布到 GitHub Release。

**编译基线：glibc 2.17（CentOS 7），单一档位** —— 产物可运行在所有 glibc ≥ 2.17 的系统上
（CentOS 7/8、Rocky、Debian 9+、Ubuntu 16.04+、麒麟 V10、openEuler 等），
按 CPU 架构分 `amd64` / `arm64` 两个包，目标机零依赖安装。

> 为什么按 glibc 基线而不是按系统逐个编译（kubekey 那种一系统一个 Dockerfile）？
> kubekey 的产物是各发行版仓库里的**原生 RPM/DEB 包**，与系统强绑定，必须逐系统做；
> 而这里是**从源码编译的 ELF 二进制**，兼容性只取决于编译机的 glibc 版本
> （编译机 glibc ≤ 运行机 glibc 即可），与发行版无关。2.17 是主流系统的最低公约数，
> 一档通吃，无需多档。

## 产物

每次构建产出（以 `17.5` 为例）：

| 文件 | 说明 |
| ---- | ---- |
| `postgresql-17.5-linux-amd64.tar.gz` | x86_64 包 |
| `postgresql-17.5-linux-arm64.tar.gz` | aarch64 包 |
| `postgresql-17.5.sha256sum.txt` | 校验文件 |

tar 包目录结构（TLS 运行库打进包内 `lib/`，通过 RPATH 引用，目标机**无需安装 openssl**）：

```
postgresql-17.5-linux-amd64/
├── bin/               # postgres initdb pg_ctl psql pg_dump pg_dumpall pg_restore
│                      # pg_basebackup pgbench createdb createuser pg_isready 等全套工具
├── lib/
│   ├── *.so           # 内置模块(上游默认直接装 lib/)
│   ├── libssl.so.1.1
│   └── libcrypto.so.1.1
└── share/             # 时区数据、扩展 SQL、sample 配置等
```

- 编译选项：`--with-openssl --with-zlib --without-readline --without-icu
  --without-lz4 --without-zstd --disable-nls`，含 **contrib 扩展**，`strip` 瘦身
- 源码来源：`https://ftp.postgresql.org/pub/source/v<version>/postgresql-<version>.tar.gz`（GitHub 兜底）
- 编译完自动做两类校验才打包：
  1. **GLIBC 符号检查**：`objdump` 确认二进制引用的最高 GLIBC 符号 ≤ 2.17，否则构建失败；
  2. **冒烟测试**：容器内以非特权用户 `initdb` → `pg_ctl start` → `psql` 建表读写 → 停库。

## 仓库结构

```
postgresql-binary/
├── base/
│   └── Dockerfile-glib2.17    # CentOS 7 基线(devtoolset-11/10 + 自编译 OpenSSL 1.1.1w + patchelf)
├── build/
│   ├── Dockerfile             # 编译镜像(下载源码 → configure/make → 打包)
│   ├── pgsql-build-binary.sh  # 容器内编译+打包脚本(含 GLIBC 检查与冒烟测试)
│   └── ci-build-binary.sh     # CI 编排脚本(建基础镜像 → 建编译镜像 → 提取产物)
└── .github/workflows/build-binary.yml
```

基础镜像与 redis-binary 项目完全同构（CentOS 7 已 EOL 带来的额外处理）：

- yum 源全部改指 vault 存档（arm64 走 altarch），支持 `ZONE=cn` 切国内镜像；
- devtoolset-11（amd64）/ devtoolset-10（arm64）：PostgreSQL 16+ 要求较新的 C 编译器，
  而 devtoolset 保证产物只引用 glibc 2.17 的老符号；
- 自编译 OpenSSL 1.1.1w 到 /usr/local（CentOS 7 系统 1.0.2 太老，`--with-openssl` 需 ≥ 1.1.0）；
- patchelf 0.19.1 用于给二进制设 RPATH `$ORIGIN/../lib`。

## 使用方法

1. 进入 GitHub 仓库 → **Actions** → **Build Binary & Release** → **Run workflow**
2. 填写 **pgsql_version**（如 `17.5`）
3. 运行完成后，到 Release 页面（tag 为 `v17.5`）下载产物

### CI 流水线

- `compile-amd64`：`ubuntu-latest` 原生编译
- `compile-arm64`：`ubuntu-24.04-arm` **原生 arm64 runner**（免费，不走 QEMU 模拟，快且稳）
- `release`：合并两架构 tarball + 生成 sha256 校验，发到 Release tag `v<版本>`
- 基础镜像不推外部 registry，直接在 runner 本地构建，用 buildx 的 **gha 缓存**加速
  （第二次构建基础镜像层直接命中缓存，秒过）

## 本地构建（可选）

需要本地安装 Docker 并启用 buildx（在仓库根目录执行，架构与本机一致）：

```bash
VERSION=17.5
ARCH=amd64

# 1. 构建基础镜像
docker buildx build --load \
  --build-arg TARGETARCH=${ARCH} \
  -t pgsql-binary:base-glib-2.17 \
  -f base/Dockerfile-glib2.17 .

# 2. 构建编译镜像并提取产物
docker buildx build --load \
  --build-arg BASE_SYSTEM_VERSION=pgsql-binary:base-glib-2.17 \
  --build-arg PGSQL_VERSION=${VERSION} \
  --build-arg TARGETARCH=${ARCH} \
  -t pgsql-binary-build:${VERSION}-${ARCH} \
  -f build/Dockerfile build/

# 3. 提取产物
docker create --name pgsql-extract pgsql-binary-build:${VERSION}-${ARCH} /bin/true
mkdir -p output && docker cp pgsql-extract:/root/output/. output/
docker rm -f pgsql-extract
```

国内网络可给第 1 步加 `--build-arg ZONE=cn`（yum 源走南大镜像）。

## 安装示例

```bash
tar -xzf postgresql-17.5-linux-amd64.tar.gz -C /usr/local/
export PATH=/usr/local/postgresql-17.5-linux-amd64/bin:$PATH

# 初始化并启动(注意:postgres 拒绝以 root 运行,请用普通用户)
initdb -D ~/pgdata -E UTF8
pg_ctl -D ~/pgdata -l ~/pgdata/postgresql.log start
psql -d postgres -c 'SELECT version();'
```

## 依赖说明（目标机需要装什么？）

什么都不用装：

- 包内 `bin/` 二进制的外部动态依赖只有 glibc 四件套（`libc/libm/libpthread/libdl`），
  它们是 glibc 本体的一部分，任何 Linux 系统必然存在；
- TLS 库（libssl/libcrypto）在包内 `lib/`，RPATH 引用，与系统 OpenSSL 版本无关；
- zlib 静态/包内提供，readline/ICU/lz4/zstd 编译时已禁用。

唯一跑不了的场景：musl 系统（Alpine）和 glibc < 2.17 的系统（CentOS 6）。
