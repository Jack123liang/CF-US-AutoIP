# CF-US-AutoIP
#* 仅用于学习 / 自用优化
#* 不提供公共服务
#* 不保证可用性
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

0 2 * * * /root/cf_auto_bestip/run_cfst_us.sh >> /root/cf_auto_bestip/logs/cfst_us.log 2>&1

0 4 * * * /root/cf_auto_bestip/push_to_kv.sh >> /root/cf_auto_bestip/logs/push_kv.log 2>&1

0 3 * * 0 > /root/cf_auto_bestip/logs/cfst_us.log && > /root/cf_auto_bestip/logs/push_kv.log

0 5 * * * SECRET=$(grep -i "^secret" /etc/openclash/Openclash_mrs.yaml | awk '{print $2}'); /usr/bin/curl -L -s '机场订阅地址' -o /etc/openclash/proxy_provider/机场名称.yaml; /usr/bin/curl -s -X PUT 'http://127.0.0.1:9090/providers/proxies/机场名称' -H "Authorization: Bearer $SECRET"

