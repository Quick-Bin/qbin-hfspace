# -------- 基础镜像 --------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DENO_INSTALL=/usr/local

# 系统依赖 + 安装 Deno + pip依赖
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        curl git sqlite3 ca-certificates python3 python3-pip unzip && \
    pip3 install --no-cache-dir --break-system-packages requests webdavclient3 && \
    curl -fsSL https://deno.land/install.sh | sh && \
    ln -s /usr/local/bin/deno /usr/bin/deno && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 新建与 Spaces 运行时一致的普通用户
RUN useradd -m -u 1000 deno
USER deno
WORKDIR /app
ENV HOME=/home/deno \
    DENO_DIR=/home/deno/.cache/deno

# 拉取 QBin 源码 & 预缓存依赖
RUN git clone --depth=1 https://github.com/Quick-Bin/qbin.git . && \
    deno cache --node-modules-dir index.ts

# 数据库生成 & 迁移
ENV DB_CLIENT=sqlite \
    SQLITE_URL="file:data/qbin_local.db"
RUN mkdir -p data && \
    sed -i -e 's/"deno"/"no-deno"/' node_modules/@libsql/client/package.json && \
    deno task db:generate && \
    deno task db:migrate && \
    deno task db:push && \
    sed -i -e 's/"no-deno"/"deno"/' node_modules/@libsql/client/package.json

COPY --chown=deno:deno --chmod=755 sync_data.sh ./sync_data.sh

# 运行参数
ENV PORT=8000
EXPOSE 8000

CMD bash -c '\
  ./sync_data.sh && \
  deno run -NER --allow-ffi --allow-sys --unstable-kv --unstable-broadcast-channel index.ts --port ${PORT:-8000}'
