一些别人收集的的padavan可以用的二进制程序


|名称|用法示例|介绍|常用参数说明|
adb-mipsel.1.0.31	./adb-mipsel devices	Android 调试桥的 MIPS 版本	devices：列出连接的设备		|adb-mipsel.1.0.31|./adb-mipsel devices|Android 调试桥的 MIPS 版本|devices：列出连接的设备|
			connect IP:端口：连接远程设备		||||connect IP:端口：连接远程设备|
arp-scan	sudo ./arp-scan --localnet	局域网 ARP 扫描工具	--localnet：扫描本地网络		|arp-scan|sudo ./arp-scan --localnet|局域网 ARP 扫描工具|--localnet：扫描本地网络|
			-I eth0：指定网卡	-I eth0：指定网卡	|
bastet	./bastet	命令行俄罗斯方块游戏	直接运行进入游戏（方向键控制）		|bastet|./bastet|命令行俄罗斯方块游戏|直接运行进入游戏（方向键控制）|
ddnsto	./ddnsto -u "your_token"	轻量级内网穿透工具	-u：绑定账户 token		|ddnsto|./ddnsto -u "your_token"|轻量级内网穿透工具|-u：绑定账户 token|
			-d：后台守护进程		|
mosquitto	./mosquitto -c mosquitto.conf	MQTT 消息代理服务	-c：指定配置文件		|mosquitto|./mosquitto -c mosquitto.conf|MQTT 消息代理服务|-c：指定配置文件|
			-v：详细日志输出		|
mosquitto_passwd	./mosquitto_passwd -b pwfile user1 pass1	MQTT 用户密码管理工具	-b：批量模式		|mosquitto_passwd|./mosquitto_passwd -b pwfile user1 pass1|MQTT 用户密码管理工具|-b：批量模式|
			-c：创建新文件		|
mosquitto_pub	./mosquitto_pub -t topic -m "hello"	MQTT 消息发布客户端	-t：主题名		|mosquitto_pub|./mosquitto_pub -t topic -m "hello"|MQTT 消息发布客户端|-t：主题名|
			-m：消息内容	-h：服务器地址	|
mosquitto_sub	./mosquitto_sub -t "#" -v	MQTT 消息订阅客户端	-t "#"：订阅所有主题		|mosquitto_sub|./mosquitto_sub -t "#" -v|MQTT 消息订阅客户端|-t "#"：订阅所有主题|
			-v：显示详细消息		|
mproxy	./mproxy -l 8080 -d	轻量级 HTTP 代理服务器	-l：监听端口		|mproxy|./mproxy -l 8080 -d|轻量级 HTTP 代理服务器|-l：监听端口|
			-d：后台运行		|
nmap	./nmap -sV 192.168.1.1	网络扫描与安全审计工具	-sV：服务版本探测		|nmap|./nmap -sV 192.168.1.1|网络扫描与安全审计工具|-sV：服务版本探测|
			-p 80,443：指定端口	-O：操作系统识别	|
sstpc	./sstpc --user u1 --password p1 server_ip	SSTP VPN 客户端	--user：用户名		|sstpc|./sstpc --user u1 --password p1 server_ip|SSTP VPN 客户端|--user：用户名|
			--password：密码		|
			--log-level 2：日志级别		|
tcpdump	sudo ./tcpdump -i eth0 port 80	网络抓包分析工具	-i：指定网卡		|tcpdump|sudo ./tcpdump -i eth0 port 80|网络抓包分析工具|-i：指定网卡|
			port：过滤端口		|
			-w file.pcap：保存抓包文件		|
tcpreplay	sudo ./tcpreplay -i eth0 file.pcap	网络流量回放工具	-i：输出网卡		|tcpreplay|sudo ./tcpreplay -i eth0 file.pcap|网络流量回放工具|-i：输出网卡|
			--loop 5：循环次数		
			--mbps 100：限速 100Mbps		|
vhclientmipsel	./vhclientmipsel -s server_ip -p 443	虚拟硬件设备客户端	-s：服务器地址		|vhclientmipsel|./vhclientmipsel -s server_ip -p 443|虚拟硬件设备客户端|-s：服务器地址|
			-p：端口		
			-v：显示连接详情		|
vhusbdmipsel	./vhusbdmipsel -d -a your_token	虚拟 USB 设备守护进程	-d：后台运行		|vhusbdmipsel|./vhusbdmipsel -d -a your_token|虚拟 USB 设备守护进程|-d：后台运行|
			-a：绑定账户 token		
			-r：重连间隔		|


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
