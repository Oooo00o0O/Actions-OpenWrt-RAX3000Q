# 独墅湖人才公寓「慧湖通」门户认证机制深度逆向与工程实践报告

> 创建时间：2026-09-19  
> 适用网络：独墅湖人才公寓（苏州市工业园区）/ 慧湖通统一融合服务门户  
> 目标硬件：CMCC RAX3000Q（高通 IPQ5000 / ImmortalWrt 21.02-SNAPSHOT）  
> 关联仓库：`https://github.com/Oooo00o0O/Actions-OpenWrt-RAX3000Q`

---

## 1. 系统网络拓扑与认证特征画像

### 1.1 新老宿舍物理网络差异
| 维度 | 旧宿舍（2026-09-16 记录） | 新宿舍（2026-09-19 实测） | 说明 |
|---|---|---|---|
| **WAN 网段** | `10.111.96.0/19` | `10.120.96.0/19` | 不同的楼栋汇聚 VLAN |
| **网关 IP** | `10.111.127.254` | `10.120.127.254` | 上游 BRAS / 三层交换机 |
| **上游 DHCP 下发 DNS** | `61.177.7.1` + `8.8.8.8` | `61.177.7.1` + `8.8.8.8` | 运营商原生推送了 Google DNS |
| **Portal 认证机** | `http://10.10.16.101:8080/eportal/` | `http://10.10.16.101:8080/eportal/` | 华为/锐捷 ePortal 统一网关 |
| **SSO 中心服务器** | `https://api.215123.cn` | `https://api.215123.cn` | 腾讯云公网 IDC (`58.210.96.145`) |

### 1.2 关键行为特征
1. **未认证状态防火墙策略（硬隔离）**：
   * **TCP/UDP 流量全阻断**：任何外网 HTTP/HTTPS/UDP 均被拦截。
   * **HTTP 劫持重定向**：访问任意未加密 HTTP 地址（如 `http://123.123.123.123/`），网关返回 HTTP 200/302，内嵌 JS 跳转至本地 ePortal 登录页。
   * **严格的 DNS 穿透白名单**：**仅放行目标为 `8.8.8.8`（及 `8.8.4.4`）的 UDP 53 数据包**。国内公共 DNS（阿里 `223.5.5.5`、腾讯 `119.29.29.29`、甚至本地下发的电信 `61.177.7.1`）在未认证前全部被上游防火墙静默丢弃。
   * **公网白名单 IP**：上游网关硬编码放行了 SSO 中心 IP `58.210.96.145`（端口 443），保证客户端在离线状态下能与云端认证中心通信。
2. **定时踢线机制**：
   * 每日约 **11:55 ~ 12:10**，RADIUS 会发起全网会话统一生命周期重置，强制将所有终端踢入离线 Portal 态。
   * 防火墙检测到非法的多设备/路由特征时，会触发惩戒期踢线（通常惩戒冷却 5~10 分钟）。

---

## 2. 三大认证凭证技术路径对比与选型终局

在独墅湖人才公寓网络中，历史上和开源社区存在三种获取认证 Token 的方式。经本次抓包与逆向交叉比对，结论如下：

```
                 ┌─ [A] 历史微信 openId 路线 (已死) ────> /web-app/ (返回 JWT) ─X─> oauthRedirect 报 500 拒绝
                 │
认证凭证三叉路口 ──┼─ [B] 网页微信扫码路线 (仅临时可用) ──> /ac/auth/isLogined ──> 随机一次性 JWT (被踢必死)
                 │
                 └─ [C] 手机号 + 识别码路线 (唯一正解) ─> /ac/auth/loginByPhoneAndUid ──> 永久无感静默换 Token
```

### 详细对比表
| 评估维度 | 路线 A：历史微信 OpenID | 路线 B：微信扫码登录（本次逆向） | 路线 C：手机号 + 识别码（当前采用） |
|---|---|---|---|
| **调用接口** | `GET /web-app/auth/certificateLogin?openId=...` | `GET /ac/auth/qrCodeLogin`<br>`POST /ac/auth/isLogined` | `POST /ac/auth/loginByPhoneAndUid` |
| **凭证参数** | 微信 OpenID | 动态 UUID（手机微信扫码授权） | 手机号 + 身份证后 8 位 |
| **凭据有效性** | ❌ **已彻底失效** | ⚠️ **仅单次临时有效** |  **永久有效（配置一次长期自愈）** |
| **交互需求** | 0 交互 | 每次断网/被踢**都必须人工拿手机扫码** | **0 交互**，后台 Cron 静默运行 |
| **被踢自愈能力** | 无 | 无法自愈（半夜断网没人扫码就永久失联） | **秒级自愈**，自动重新换 Token 放行 |
| **协议现状** | 签发的 Token 被 `/ac/` 隔离拒收（报 500） | 成功签发临时 `satoken`，可完成登录 | 官方正式渠道，无限次签发有效 `satoken` |

---

## 3. 微信扫码登录协议抓包与逆向档案

针对用户提出的“微信扫码登录是否返回 OpenID、能否作为路由器备用登录路径”，我们利用 CDP 实时拦截工具（`capture_wechat.mjs`）进行了全链路抓包实测。

### 3.1 扫码通信全过程实录

#### 第一阶段：获取动态二维码
* **请求**：
  ```http
  GET /ac/auth/qrCodeLogin?clientId=6d6bc6f3b5f04107a5fc1c62e39dd5f4 HTTP/1.1
  Host: api.215123.cn
  ```
* **响应**：
  ```json
  {
    "success": true,
    "code": 200,
    "data": {
      "path": "https://broadband.215123.cn",
      "clientId": "6d6bc6f3b5f04107a5fc1c62e39dd5f4",
      "uuid": "0655888e938040e2a08203f742299280",
      "type": "pc",
      "expire": 1789806630117
    }
  }
  ```
* **前端行为**：将 `${path}?clientId=${clientId}&uuid=${uuid}&type=${type}` 生成二维码展示给用户。

#### 第二阶段：轮询扫码确认状态（每 3 秒一拍）
* **请求**：
  ```http
  POST /ac/auth/isLogined HTTP/1.1
  Host: api.215123.cn
  Content-Type: application/json

  {"clientId":"6d6bc6f3b5f04107a5fc1c62e39dd5f4","type":"pc","uuid":"0655888e938040e2a08203f742299280"}
  ```
* **扫码前响应**：`{"code": 500, "message": "未确认登录", "data": null}`。
* **手机微信确认后响应**：
  ```json
  {
    "code": 200,
    "message": "操作成功！",
    "data": {
      "account": null,
      "name": null,
      "tokenName": "satoken",
      "token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJsb2dpblR5cGUiOiJsb2dpbiIsImxvZ2luSWQiOiJOT05FOjE4MjgzNzQ2Mzc2OTA1MzU5MzciLCJyblN0ciI6Ik81WGVsVmk2TnJmeHhVaVJhQnB6d05PR1hEOGZKU1AyIn0..."
    }
  }
  ```

#### 第三阶段：解密 Token Payload（确证无 OpenID）
对响应中的 JWT 载荷进行 Base64 解码：
```json
{
  "loginType": "login",
  "loginId": "NONE:1828374637690535937",
  "rnStr": "O5XelVi6NrfxxUiRaBpzwNOGXD8fJSP2"
}
```
* **字段事实**：
  1. 没有任何 OpenID 字段；
  2. `loginId` 只是平台用户 ID（19 位固定数字）；
  3. `rnStr` 是一次性随机防重放字符串；
  4. 该 Token 的生命周期受服务端 session 控制，在发生断网或踢线时立即作废。

#### 结论
**微信扫码登录只适合人工即时救急，无法作为路由器的无人值守保活路径。因此无需引入该复杂度。**

---

## 4. 路由器嵌入式环境的两个致命底层缺陷与修复

在本次排查中，发现了导致路由器开机初次自动登录失败的两个隐蔽底层缺陷，并已完成针对性修复：

### 4.1 缺陷一：`musl libc` 限制 `MAXNS = 3` 导致 8.8.8.8 被静默丢弃

#### 根因剖析
1. 用户在 `/etc/config/dhcp` 中配置了 `dnsmasq.allservers='1'`，误以为系统解析会自动全并发。
2. 然而，**路由器内部脚本（`curl`）解析域名不走 dnsmasq**，而是直接读取 `/etc/resolv.conf`（指向 WAN 口的 `resolv.conf.auto`），交由 C 运行库 `musl libc` 处理。
3. `musl libc` 源码（`include/resolv.h`）硬编码了上限：
   ```c
   #define MAXNS 3
   ```
   解析器读满 3 行 `nameserver` 后，**第 4 行及以后的所有 DNS 直接被静默丢弃**！
4. 路由器原配置顺序为：`223.5.5.5` -> `223.6.6.6` -> `119.29.29.29` -> `119.28.28.28` -> `8.8.8.8`。
   * 排在第 5 位的 **`8.8.8.8` 根本没有被 musl 载入**！
   * 掉线被劫持时，前 3 个国内 DNS 全被物业防火墙封死，curl 最终因等待超时报 `curl: (28) Resolving timed out after 5000 milliseconds`。

#### 解决方案与 Git 固化
1. 将 WAN 口 DNS 列表精简并严格控制在 3 个以内：
   ```sh
   uci -q delete network.wan.dns
   uci add_list network.wan.dns='8.8.8.8'
   uci add_list network.wan.dns='223.5.5.5'
   uci add_list network.wan.dns='119.29.29.29'
   uci commit network
   ```
2. 该修改已同步写入编译仓库的 `Actions-OpenWrt-RAX3000Q/files/etc/uci-defaults/99-custom-settings`（Commit: `c587806`），确保刷机开机即生效。

---

### 4.2 缺陷二：路由器无 RTC 导致开机时钟漂移与证书校验崩塌

#### 根因剖析
1. RAX3000Q 等家用路由器无板载纽扣电池，开机由 `sysfixtime` 恢复为文件系统的最后修改时间（可能停留在数天前甚至一年前）。
2. 在掉线状态下，上游防火墙**阻断了所有 UDP 123（NTP）数据包**，登录成功前外网 NTP 无法对时。
3. 若系统时间退回 2025 年或出厂 2024 年，访问 `https://api.215123.cn` 时，curl 会因证书有效起始期（`2026-07-14`）未到，抛出 `SSL: certificate is not yet valid` 导致握手彻底失败。
4. 错误的时钟还会导致存活时长计算出几万秒的荒谬数字，破坏日志台账。

#### 解决方案（双重时间自愈引擎）
已在 `portal-autologin.sh` 与 `portal-login.sh` 中实现闭环防御：
1. **HTTP Date 秒级提取自愈**：
   在第 1 步探测 `http://123.123.123.123/` 时，无论是否断网，网关返回的 HTTP 响应头必带服务器真实 `Date:`。脚本通过正则提取并调用 `date -u -D ... -s` 校验本地时钟，进入 HTTPS 步骤前系统时间已对齐。
2. **CURL 增加 `-k` 免疫校验**：
   在 `portal-login.sh` 的 HTTPS 请求中加入 `-k`（`--insecure`），即使极端时钟漂移也绝不阻断换 Token 过程。
3. **放行瞬间即时 NTP 锁准**：
   登录成功网络放行的第 0.1 秒，立即触发 `ntpd -q -p ntp.aliyun.com` 将时钟拉升至毫秒级精度，再刷新 `$BASE` 会话起点与落盘日志。

---

## 5. 社区三个开源项目的横向对比与技术借鉴

针对 GitHub 上的三个代表性项目进行了深入研读：

| 开源项目 | 核心机制 | 优缺点深度评价 | 对当前项目的启示与借鉴 |
|---|---|---|---|
| **[Dustella/Huihutong-portal-login](https://github.com/Dustella/Huihutong-portal-login)** | Bash/Python<br>`openId` 换 Token | ❌ **已失效**。采用旧版 `/web-app/` 接口，已被平台 OAuth 彻底封杀（报 500）。无任何容错与系统守护。 | 确认了 `openId` 路线的不可行性，避免踩坑。 |
| **[Zerlight/huihu-wenyuan-login-sh](https://github.com/Zerlight/huihu-wenyuan-login-sh)** | POSIX Shell<br>纯内网锐捷 SAM API | ⚠️ **拓扑不兼容**。针对文缘宿舍内网认证，与独墅湖公网 SSO 无法通用。 | 借鉴了其**日志滚动截断（64KB 限制）**与**指数退避重试**的设计规范。 |
| **[lithiumspectrum/huihutong-broadband-autologin-script](https://github.com/lithiumspectrum/huihutong-broadband-autologin-script)** | Python 3 (daemon)<br>`phone + uid` 换 Token |  **最高价值参考**。包含了完整的 46KB 逆向技术档案，与我们当前采用的凭证路径完全一致。 | 1. 证实了每日 12:00 的 RADIUS 踢线规律；<br>2. 验证了 `loginByPhoneAndUid` 是唯一永久正解。 |

### 架构决策优势
* **内存对比**：`lithiumspectrum` 使用 Python 常驻后台（占用 ~20MB RAM）；我们的方案采用 **OpenWrt 原生 Shell + Busybox Crond（每 2 分钟触发）**，平时 **0 内存占用**，执行仅耗时 ~0.3s，极其契合 RAX3000Q（184MB 物理内存）的极致轻量化要求。

---

## 6. 修改落地清单与提交记录

| 文件路径 | 变更要点 | 状态 |
|---|---|---|
| `files/etc/uci-defaults/99-custom-settings` | WAN DNS 调整为 `8.8.8.8` 首位 + 阿里云/腾讯云（共 3 个，兼容 musl MAXNS） | 已推送到 GitHub（Commit: `c587806`） |
| `files/usr/bin/portal-login.sh` | 各关键请求放宽超时至 10s/20s，HTTPS 请求补全 `-k` 跳过时钟证书校验 | 已推送到 GitHub（Commit: `1050f5b`）<br>已同步部署至路由器 |
| `files/usr/bin/portal-autologin.sh` | 增加 HTTP Date 前置自愈对时，放行瞬间强制 NTP 对齐，重试冷却缩短至 5 分钟 | 已推送到 GitHub（Commit: `1050f5b`）<br>已同步部署至路由器 |
| `capture_wechat.mjs` | 基于 CDP 的 Chromium 实时流量拦截与分析工具，自动捕获扫码全流程 | 本地就绪，测试通过 |
