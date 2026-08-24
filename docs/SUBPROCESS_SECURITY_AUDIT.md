# KOReader 2026.03 一次性凭证子进程审计

状态：**固定版本源码审计与合成门禁；真实凭证传输仍未启用**。

本文判断 KOReader 可取消子进程是否适合未来的一次性扫码凭证。结论只覆盖指定源码的数据通道，不覆盖尚未实现的 HTTP、Cookie、Passport、日志配置、崩溃收集或真机内核行为。

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
- 每次只传回一个已经限制大小的字符串，由父进程按协议严格解析。
- 子任务内部不得 logger、`print()`、写文件、启用持久 Cookie jar 或回显原始异常。
- QR、轮询、取书架和退出各阶段仍由 `ephemeral_session.lua` 管理状态与引用。

以下事实完成前仍是 No-Go：

1. 真实 HTTP/Cookie 客户端的请求头、错误、重定向、Cookie jar 和 stdout/stderr 行为完成逐行审计。
2. 网络读取在形成完整 Lua 字符串前已有响应大小和总超时限制。
3. 取消、TLS 错误、解析错误和退出失败的 KOReader 日志/崩溃输出通过合成 canary 扫描。
4. PW3 上验证任务前后没有新增临时文件、Cookie 文件或响应转储。
5. 测试账号验证 `SIGKILL` 后远端会话自然失效时间及主动撤销路径。

在这些条件完成前，`ephemeral_task.lua` 只是安全边界原型，不是启用真实扫码的许可。
