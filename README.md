# CF-US-AutoIP
## 重装步骤

1. 创建目录
mkdir -p /root/cf_auto_bestip/data /root/cf_auto_bestip/logs

2. 克隆脚本
git clone https://github.com/Jack123liang/CF-US-AutoIP.git /root/cf_auto_bestip

4. 下载 cfst 二进制
cd /root/cf_auto_bestip
wget -O cfst.tar.gz https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.4/CloudflareST_linux_arm64.tar.gz
tar -xzf cfst.tar.gz && chmod +x cfst && rm cfst.tar.gz

5. 创建 .env 填入敏感数据
cp .env.example .env
vi .env
(.env真实数据存于iCloud）

6. 赋权

   (chmod +x /root/cf_auto_bestip/run_cfst_us.sh）

   (chmod +x /root/cf_auto_bestip/push_to_kv.sh)

 6.验证

   cd /root/cf_auto_bestip
   
   ./run_cfst_us.sh && ./push_to_kv.sh

7. 设置 crontab
    crontab -e
