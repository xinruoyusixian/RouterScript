一些别人收集的的padavan可以用的二进制程序

## 嵌入式工具集 (MIPS 架构)

| 工具名称             | 用法示例                              | 功能描述                     | 关键参数说明                     |
|----------------------|---------------------------------------|------------------------------|----------------------------------|
| **adb-mipsel**       | `./adb-mipsel devices`                | Android 设备调试工具         | `connect IP:端口` - 连接设备     |
| **arp-scan**         | `sudo ./arp-scan --localnet`          | 局域网设备扫描               | `-I eth0` - 指定网卡             |
| **ddnsto**           | `./ddnsto -u "your_token" -d`         | 内网穿透工具                 | `-u` - 账户令牌，`-d` - 后台运行 |
| **mosquitto**        | `./mosquitto -c mosquitto.conf -v`    | MQTT 消息代理                | `-c` - 配置文件，`-v` - 详细日志 |
| **mosquitto_passwd** | `./mosquitto_passwd pwfile user`      | MQTT 用户管理                | `-b` - 批量模式                 |
| **mosquitto_pub**    | `./mosquitto_pub -t topic -m "msg"`   | MQTT 消息发布                | `-t` - 主题，`-m` - 消息内容    |
| **mosquitto_sub**    | `./mosquitto_sub -t "#" -v`           | MQTT 消息订阅                | `-t "#"` - 订阅所有主题         |
| **mproxy**           | `./mproxy -l 8080 -d`                 | HTTP 代理服务器              | `-l` - 监听端口                 |
| **nmap**             | `./nmap -sV 192.168.1.1`              | 网络扫描与安全审计           | `-sV` - 服务探测，`-p` - 端口   |
| **sstpc**            | `./sstpc --user u1 server_ip`         | SSTP VPN 客户端              | `--password p1` - 密码          |
| **tcpdump**          | `sudo ./tcpdump -i eth0 port 80`      | 网络抓包分析                 | `-w file.pcap` - 保存抓包文件   |
| **tcpreplay**        | `sudo ./tcpreplay -i eth0 file.pcap`  | 网络流量回放                 | `--loop 5` - 循环次数           |
| **vhclientmipsel**   | `./vhclientmipsel -s server_ip -p 443`| 虚拟硬件客户端               | `-v` - 显示详情                 |
| **vhusbdmipsel**     | `./vhusbdmipsel -a token -d`          | 虚拟 USB 守护进程            | `-a` - 账户令牌                 |

### 游戏工具
| 工具名称       | 用法         | 功能描述         |
|----------------|--------------|------------------|
| **bastet**     | `./bastet`   | 俄罗斯方块       |
| **nInvaders**  | `./nInvaders`| 太空入侵者       |
| **nsnake**     | `./nsnake`   | 贪吃蛇           |
| **nudoku**     | `./nudoku`   | 数独游戏         |

### 使用提示
```bash
# 查看帮助信息
./工具名 --help 或 -h

# 后台运行服务
./ddnsto -u "token" > /dev/null 2>&1 &

# 权限修复
chmod +x 文件名

特殊工具：

nInvaders/nsnake/nudoku：直接执行 ./文件名 启动游戏（无复杂参数）

smbmulti3.0.37：SMB文件共享客户端，用法类似 ./smbmulti //IP/share

vhweb-mipsel-linux：嵌入式Web服务，通常 ./vhweb-mipsel-linux -p 8080

通用技巧：

bash
# 查看帮助信息（大部分工具支持）
./二进制文件名 --help 或 -h

# 后台运行（适用于服务类工具）
./ddnsto -u "token" > /dev/null 2>&1 &

# 权限修复（若无法执行）
chmod +x 文件名
💡 提示：MQTT 工具链典型工作流

启动服务：./mosquitto -c mosquitto.conf

添加用户：./mosquitto_passwd -c pwfile username

订阅消息：./mosquitto_sub -t "sensors/#" -u username -P password

发布消息：./mosquitto_pub -t "sensors/temp" -m "25C" -u username -P password
