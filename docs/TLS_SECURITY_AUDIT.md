# 公开 HTTPS 证书校验审计

## 结论

目标环境 KOReader v2026.03 随包 LuaSec 1.3.2 的 `ssl.https.request` 默认不验证服务端证书，并且即使调用方开启证书链验证，该 Lua 封装也不会自动核对证书 SAN 与请求主机名。插件此前直接使用默认请求，因此源码证据不足以证明公开 GET 能拒绝错误证书。这里描述的是源代码层风险，不代表已经观察到中间人攻击或数据泄露。

开发分支现已显式使用 KOReader 自带 CA 集验证证书链，并在握手后校验证书 SAN。任何链验证失败、证书缺失、SAN 缺失、扩展解析失败或主机名不匹配都会关闭连接并安全失败。公开 GET 与未启用的敏感请求原型共用该连接器；后者仍无真实端点、Cookie 语义或流程接线，不能据此宣称扫码客户端已经安全。

## 固定证据

- KOReader 版本固定为 [`v2026.03` 提交 `825b9bc`](https://github.com/koreader/koreader/commit/825b9bced0eb666b45af4208e1c0095b88d38b0d)，对应 `koreader-base` 提交为 [`7a46ea3`](https://github.com/koreader/koreader-base/tree/7a46ea3812539083ee25b06f0c81ac58b1356ee0)。
- `koreader-base` 在该提交中构建 [LuaSec v1.3.2](https://github.com/koreader/koreader-base/blob/7a46ea3812539083ee25b06f0c81ac58b1356ee0/thirdparty/luasec/CMakeLists.txt)。[LuaSec v1.3.2 `https.lua`](https://github.com/brunoos/luasec/blob/v1.3.2/src/https.lua) 的默认值是 `verify = "none"`；连接流程设置 SNI 并握手，但没有主机名验证。
- [LuaSec v1.3.2 `x509.c`](https://github.com/brunoos/luasec/blob/v1.3.2/src/x509.c) 可通过 `certificate:extensions()` 提供 SAN 的 `dNSName`，但没有在 `https.lua` 中自动使用它验证主机名。
- 官方 [`koreader-kindle-v2026.03.zip`](https://github.com/koreader/koreader/releases/download/v2026.03/koreader-kindle-v2026.03.zip) 的 SHA-256 为 `644aa22dd36893af4a67471953c73c444aae12b536410892220f5c376f2bf39e`。包内 `koreader/data/ca-bundle.crt` 为 225076 字节、144 张证书，SHA-256 为 `f1407d974c5ed87d544bd931a278232e13925177e239fca370619aba63c757b4`。
- KOReader 的 [`datastorage.lua`](https://github.com/koreader/koreader/blob/v2026.03/frontend/datastorage.lua) 在 Kindle 启动布局下将数据目录解析到 KOReader 根目录，因此运行时 CA 路径为 `DataStorage:getDataDir() .. "/data/ca-bundle.crt"`。

## 实现边界

`fanqielite/verified_tls.lua` 提供唯一的 LuaSec 自定义连接器，公开 `http.lua` 和未启用的 `ephemeral_http.lua` 共用以下设置：

- `verify = "peer"`；
- `cafile` 指向 KOReader 随包 CA 集；
- 禁用 SSLv2、SSLv3、TLS 1.0 和 TLS 1.1；
- 握手后读取叶证书 SAN，不使用 CN 回退；
- 精确名称按大小写不敏感匹配；通配符只允许最左侧一个标签，例如 `*.example.com` 不匹配 `example.com` 或 `a.b.example.com`；
- 缺少证书、SAN 或可解析扩展时遇错即停并关闭连接；
- 检测到 LuaSocket 全局 HTTP 代理时在连接前拒绝；
- 继续拒绝重定向，并保留 1 MB 响应上限和固定中文错误。

合成测试验证了正确 SAN、错误 SAN、缺少 SAN、通配符错误匹配、缺少证书和扩展解析异常，也锁定 `verify`、CA 路径与旧协议禁用选项。测试不会连接番茄官网，不包含账号或 Cookie。

## 尚未覆盖

- PW3 上对官方站点的真实 TLS 握手与正文读取；
- 系统时间错误、CA 文件缺失或损坏时的真机提示；
- 断网、Wi-Fi 切换、DNS 长时间阻塞和证书轮换；
- CRL、OCSP 或其他实时撤销检查；
- 未来扫码真实端点的 Cookie 语义、任务编排、日志复核和退出行为。

上述真机项完成前，只能说实现和合成测试已补强，不能宣称目标设备上的 TLS 门禁已经验收。
