#!/bin/bash

# 检查环境变量
if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
    echo "缺少 WEBDAV_URL、WEBDAV_USERNAME 或 WEBDAV_PASSWORD，启动时将不包含备份功能"
    exit 0
fi

# 设置备份路径
WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-""}
FULL_WEBDAV_URL="${WEBDAV_URL}"
if [ -n "$WEBDAV_BACKUP_PATH" ]; then
    FULL_WEBDAV_URL="${WEBDAV_URL}/${WEBDAV_BACKUP_PATH}"
fi

# 下载最新备份并恢复
restore_backup() {
    echo "开始从 WebDAV 下载最新备份..."
    python3 -c "
import sys
import os
import tarfile
import requests
from webdav3.client import Client
import shutil
options = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD'
}
client = Client(options)
backups = [file for file in client.list() if file.endswith('.tar.gz') and file.startswith('qbin_backup_')]
if not backups:
    print('没有找到备份文件')
    sys.exit()
latest_backup = sorted(backups)[-1]
print(f'最新备份文件：{latest_backup}')
with requests.get(f'$FULL_WEBDAV_URL/{latest_backup}', auth=('$WEBDAV_USERNAME', '$WEBDAV_PASSWORD'), stream=True) as r:
    if r.status_code == 200:
        with open(f'/tmp/{latest_backup}', 'wb') as f:
            for chunk in r.iter_content(chunk_size=8192):
                f.write(chunk)
        print(f'成功下载备份文件到 /tmp/{latest_backup}')
        if os.path.exists(f'/tmp/{latest_backup}'):
            # 解压备份文件到临时目录
            temp_dir = '/tmp/restore'
            os.makedirs(temp_dir, exist_ok=True)
            tar = tarfile.open(f'/tmp/{latest_backup}', 'r:gz')
            tar.extractall(temp_dir)
            tar.close()
            # 查找并移动 qbin_local.db 文件
            for root, dirs, files in os.walk(temp_dir):
                if 'qbin_local.db' in files:
                    db_path = os.path.join(root, 'qbin_local.db')
                    os.makedirs('/app/data', exist_ok=True)
                    os.replace(db_path, '/app/data/qbin_local.db')
                    print(f'成功从 {latest_backup} 恢复备份文件')
                    break
            else:
                print('备份文件中未找到 qbin_local.db')
            # 删除临时目录
            try:
                shutil.rmtree(temp_dir)
            except Exception as e:
                print(f'删除临时目录时出错：{e}')
            os.remove(f'/tmp/{latest_backup}')
        else:
            print('下载的备份文件不存在')
    else:
        print(f'下载备份失败：{r.status_code}')
"
}

# 首次启动时下载最新备份
echo "正在从 WebDAV 下载最新备份..."
restore_backup

# 同步函数
sync_data() {
    while true; do
        echo "在 $(date) 开始同步进程"

        if [ -f "/app/data/qbin_local.db" ]; then
            timestamp=$(date +%Y%m%d_%H%M%S)
            backup_file="qbin_backup_${timestamp}.tar.gz"

            # 打包数据库文件
            tar -czf "/tmp/${backup_file}" /app/data/qbin_local.db

            # 上传新备份到WebDAV
            curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "/tmp/${backup_file}" "$FULL_WEBDAV_URL/${backup_file}"
            if [ $? -eq 0 ]; then
                echo "成功将 ${backup_file} 上传至 WebDAV"
            else
                echo "上传 ${backup_file} 至 WebDAV 失败"
            fi

            # 清理旧备份文件
            python3 -c "
import sys
from webdav3.client import Client
options = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD'
}
client = Client(options)
backups = [file for file in client.list() if file.endswith('.tar.gz') and file.startswith('qbin_backup_')]
backups.sort()
if len(backups) > 5:
    to_delete = len(backups) - 5
    for file in backups[:to_delete]:
        client.clean(file)
        print(f'成功删除 {file}。')
else:
    print('仅找到 {} 个备份，无需清理。'.format(len(backups)))
" 2>&1

            rm -f "/tmp/${backup_file}"
        else
            echo "数据库文件尚不存在，等待下次同步..."
        fi

        SYNC_INTERVAL=${SYNC_INTERVAL:-600}
        echo "下次同步将在 ${SYNC_INTERVAL} 秒后进行..."
        sleep $SYNC_INTERVAL
    done
}

# 后台启动同步进程
sync_data &
