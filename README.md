# update_rds_whitelist
# ---------------------------
# 阿里云RDS白名单更新脚本（纯净输出版）
# 版本：24.0
# ---------------------------

# 配置区
# 阿里云的key
ACCESS_KEY_ID="xxx"
# 阿里云的密钥
ACCESS_KEY_SECRET="xxx"
# 服务器所在的区域
REGION_ID="cn-shanghai"
# 实例的id
INSTANCE_ID="rm-ufxxxxxxx"
# 白名单分组的名字
SECURITY_GROUP_NAME="xxxxx"
# 临时缓存ip的文件
IP_FILE="/tmp/last_ip.txt"
# 输出的日志文件
LOG_FILE="/tmp/rds_whitelist.log"

个人博客地址：https://urlzd.cn/t/huPvQfJ
