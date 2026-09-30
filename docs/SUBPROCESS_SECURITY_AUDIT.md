# KOReader 2026.03 一次性凭证子进程审计

状态：**固定版本源码审计、实验性扫码接线与合成门禁；PW3 测试账号验收未完成**。

本文判断 KOReader 可取消子进程是否适合一次性扫码凭证。结论覆盖指定源码的数据通道、敏感 HTTPS 门禁、内存 Cookie jar、固定 Passport/书架协议和最小书架结果门禁；不替代真实账号、完整任务日志、崩溃收集或真机内核行为的验收。

## 固定版本

- KOReader `v2026.03`：提交 [`825b9bc`](https://github.com/koreader/koreader/commit/825b9bced0eb666b45af4208e1c0095b88d38b0d)。
- 对应 `koreader-base`：提交 [`7a46ea3`](https://github.com/koreader/koreader-base/tree/7a46ea3812539083ee25b06f0c81ac58b1356ee0)。
- 上层入口：[`frontend/ui/trapper.lua`](https://github.com/koreader/koreader/blob/v2026.03/frontend/ui/trapper.lua) 的 `dismissableRunInSubprocess()`。
- 底层实现：[`ffi/util.lua`](https://github.com/koreader/koreader-base/blob/7a46ea3812539083ee25b06f0c81ac58b1356ee0/ffi/util.lua) 的 `runInSubProcess()`、`writeToFD()`、`readAllFromFD()`和 `terminateSubProcess()`。

## 数据路径

1. `runInSubProcess(..., true)`调用 POSIX `pipe()`后 `fork()`。
2. 子进程只通过匿名管道的写端传回结果，父进程从读端读取；这段实现没有创建命名文件或临时路径。
3. 默认复杂返回值会用 `string.buffer` 编码，再写入管道；父进程读出后解码。
4. `task_returns_simple_string=true`时跳过复杂序列化，单个字符串直接写入匿名管道。
5. 管道和 Lua 字符串都只提供运行期内存引用；这不等于密码学内存清零，也不能排除操作系统、调试器或进程转储层面的副本。

因此可以合理推断：**固定源码中的 IPC 本身不需要把返回值写入用户分区**。但 KOReader 注释明确允许子任务自行修改文件系统；是否落盘仍取决于传入的任务、HTTP 库、Cookie 处理和任何调试代码，不能由匿名管道替它们担保。

## 日志与错误路径

直接把凭证交给默认复杂通道仍不可接受：

- 复杂结果编码失败时，`Trapper`会调用 logger 记录序列化失败。
- 解码畸形数据时会调用 logger 记录失败对象。
- 简单字符串模式收到非字符串时会把错误返回值交给 logger。
- 底层子进程未捕获异常时，`ffi/util.lua` 会把完整堆栈打印到进程输出。
- 任务自己调用 logger、`print()`或使用会输出请求信息的库，匿名管道无法阻止。

`ephemeral_task.lua` 因此只允许受信任函数返回一个非空字符串：子任务内部先 `pcall()`，异常值不做 `tostring()`；成功和失败使用固定二进制帧；调用 `Trapper`时强制启用简单字符串模式；父进程再次验证帧和 256 KB 上限。提示、取消、异常、格式错误和超限全部使用固定中文文本，不拼接返回值。

## 最小书架出管道门禁

简单字符串模式本身仍允许任务误把 Cookie 或原始响应作为字符串返回。`ephemeral_result.lua` 因此先在子进程内调用现有 `Import.validate()`，拒绝未知/凭证字段、非法 ID、非连续数组、超量书籍和超长文本；随后只从标准化书籍重新构造版本化最小 JSON，删除 `exported_at` 等非必要字段。编码结果不超过 256 KB，并立即解码后再次通过同一验证器。

文件导入使用 `ephemeral_import_task.lua`；实验性扫码使用 `qr_import_task.lua`。扫码确认前，父进程只短暂持有预授权轮询票据；确认后的认证 Cookie、书架请求、退出尝试和最小结果编码都留在同一个子进程。父进程收到结果后再次解码验证，只返回标准化书籍对象；验证失败使用固定提示，不回显管道内容。合成 canary 覆盖生产者异常、Cookie 字段、编解码器异常、复验时出现凭证字段和管道篡改。相关模块都不导入 logger、不调用 `print()`、`io`、`os` 或 `tostring(error)`。

该门禁只能识别结构和字段名，不能判断真实解析器是否错误地把一段秘密值填入合法的 `title` 字段。真实端点解析器仍必须逐字段选择、独立测试并扫描成功管道内容；原始响应表不得直接传给此模块。

## 取消与强制退出

用户取消时，KOReader 对整个子进程组发送 `SIGKILL`，随后异步回收进程并清空匿名管道。优点是子任务不会继续运行；安全限制是：

- 子进程没有机会执行 Lua `finally`、退出接口、Cookie 清理或缓冲区覆写。
- 已发送到官方服务的会话只能依赖服务端短时效、父进程后续退出尝试或用户撤销。
- 如果子任务此前创建过文件、Cookie jar 或日志，取消不会自动删除它们。
- 进程被杀不能证明凭证已从所有物理内存位置可靠擦除。

所以取消后的本地安全必须依赖“任务从不落盘、父进程无条件删除自身引用”，不能依赖子进程善后；远端安全还必须用测试账号验证短时失效和撤销路径。

## 当前决策

当前只允许以下实验性窄路径：

- 使用 `ephemeral_task.lua`；不得让凭证走现有 `networktask.lua` 的复杂返回通道。
- 文件导入通过 `ephemeral_import_task.lua`，扫码导入通过 `qr_import_task.lua`；两者都只传回经过标准化和双重复验的最小书架 JSON。
- 子任务内部不得 logger、`print()`、写文件、启用持久 Cookie jar 或回显原始异常。
- `ephemeral_session.lua` 管理父进程中的预授权票据和最终确认状态；扫码确认后的认证 Cookie 不返回父进程。
- `ephemeral_cookiejar.lua` 只在子进程内合并受限 Cookie，流程结束或失败后清除引用；不得保存原始响应表或共享调用方可修改的表引用。

以下事实完成前仍不得升级为稳定能力：

1. 用专用测试账号验证真实成功响应、认证 Cookie 集合、二次验证和退出语义。
2. 扫描取消、TLS 错误、解析错误和退出失败时的 KOReader 日志/崩溃输出。
3. 在 PW3 上验证任务前后没有新增临时文件、Cookie 文件或响应转储。
4. 验证 `SIGKILL` 后远端会话自然失效时间及主动撤销路径。
5. 验证二维码在 PW3 上可读、过期/取消/断网能安全回退且现有书架不变。

在这些条件完成前，该实现只能保留“实验性”标识，不得作为稳定版登录能力或建议主要账号首次尝试。
