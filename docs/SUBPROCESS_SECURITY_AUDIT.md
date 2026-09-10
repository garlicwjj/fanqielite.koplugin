# KOReader 2026.03 一次性凭证子进程审计

状态：**固定版本源码审计与合成门禁；真实凭证传输仍未启用**。

本文判断 KOReader 可取消子进程是否适合未来的一次性扫码凭证。结论覆盖指定源码的数据通道、端点无关敏感 HTTPS 门禁和最小书架结果门禁，不覆盖尚未实现的真实 HTTP 端点、Cookie 语义、Passport、完整任务日志、崩溃收集或真机内核行为。

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

`ephemeral_import_task.lua` 才把这段复验后的 JSON 交给 `ephemeral_task.lua`。父进程收到字符串后再次解码验证，只返回标准化书籍对象；父进程验证失败使用固定提示，不回显管道内容。合成 canary 覆盖生产者异常、Cookie 字段、编解码器异常、复验时出现凭证字段和管道篡改。两个模块都不导入 logger、不调用 `print()`、`io`、`os` 或 `tostring(error)`，且 `main.lua` 未导入该入口。

该门禁只能识别结构和字段名，不能判断真实解析器是否错误地把一段秘密值填入合法的 `title` 字段。真实端点解析器仍必须逐字段选择、独立测试并扫描成功管道内容；原始响应表不得直接传给此模块。

## 取消与强制退出

用户取消时，KOReader 对整个子进程组发送 `SIGKILL`，随后异步回收进程并清空匿名管道。优点是子任务不会继续运行；安全限制是：

- 子进程没有机会执行 Lua `finally`、退出接口、Cookie 清理或缓冲区覆写。
- 已发送到官方服务的会话只能依赖服务端短时效、父进程后续退出尝试或用户撤销。
- 如果子任务此前创建过文件、Cookie jar 或日志，取消不会自动删除它们。
- 进程被杀不能证明凭证已从所有物理内存位置可靠擦除。

所以取消后的本地安全必须依赖“任务从不落盘、父进程无条件删除自身引用”，不能依赖子进程善后；远端安全还必须用测试账号验证短时失效和撤销路径。

## 当前决策

允许继续原型开发的仅是以下窄路径：

- 使用 `ephemeral_task.lua`；不得让凭证走现有 `networktask.lua` 的复杂返回通道。
- 每次只通过 `ephemeral_import_task.lua` 传回经过标准化和双重复验的最小书架 JSON，由父进程再次解析。
- 子任务内部不得 logger、`print()`、写文件、启用持久 Cookie jar 或回显原始异常。
- QR、轮询、取书架和退出各阶段仍由 `ephemeral_session.lua` 管理状态与引用。
- 授权结果进入会话前必须映射为固定的 `cookie`、`authorization`、`csrf_token`、`logout_ticket` 字段；不得保存原始响应表或共享调用方可修改的表引用。

以下事实完成前仍是 No-Go：

1. 端点无关敏感 HTTPS 客户端与最小书架出管道门禁已有逐行实现和合成测试；真实端点、成功正文解析器、Cookie 合并/过期及轮询/退出任务仍须逐项审计。
2. 网络读取在形成完整 Lua 字符串前已有响应大小和总超时限制。
3. 取消、TLS 错误、解析错误和退出失败的 KOReader 日志/崩溃输出通过合成 canary 扫描。
4. PW3 上验证任务前后没有新增临时文件、Cookie 文件或响应转储。
5. 测试账号验证 `SIGKILL` 后远端会话自然失效时间及主动撤销路径。

在这些条件完成前，`ephemeral_task.lua` 只是安全边界原型，不是启用真实扫码的许可。
