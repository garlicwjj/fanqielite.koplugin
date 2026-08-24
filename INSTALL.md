# Fanqie Lite 5 分钟安装指南

本文只适用于**已经能够正常打开 KOReader** 的 Kindle。当前文件是候选测试包说明，不代表稳定版已经发布。

## 安装前准备

- 一台已安装 KOReader 的 Kindle。
- 一根可以传输数据的 USB 线。
- 项目所有者提供的 `fanqielite-koreader-candidate-<提交号>.zip` 候选测试包。

不需要安装 App、复制 Cookie、登录番茄账号或执行终端命令。

## 0–1 分钟：解压并检查目录

在电脑上解压候选包。解压后应直接得到：

```text
fanqielite.koplugin/
├── _meta.lua
├── main.lua
└── fanqielite/
```

如果看到 `fanqielite-koreader-candidate/fanqielite.koplugin/` 或连续两层 `fanqielite.koplugin/`，不要复制外层目录，只复制包含 `_meta.lua` 的那一层。

## 1–3 分钟：复制插件

1. 先退出 KOReader，回到 Kindle 主界面。
2. 用 USB 连接电脑，打开 Kindle 磁盘。
3. 打开 `koreader/plugins/`。
4. 把整个 `fanqielite.koplugin` 文件夹复制进去，最终路径必须是：

```text
koreader/plugins/fanqielite.koplugin/main.lua
```

首次安装不需要修改 `koreader` 内的其他文件。

如果是升级测试，先把原来的 `fanqielite.koplugin` 完整复制到电脑备份，再只替换这个插件目录。书架设置和章节缓存位于插件目录之外，不要删除。

## 3–4 分钟：安全弹出并重启 KOReader

1. 在电脑上安全弹出 Kindle 磁盘。
2. 拔掉 USB 线。
3. 重新打开 KOReader；如果 KOReader 原本没有退出，请执行一次完整退出后重新进入。

## 4–5 分钟：加入第一本书

1. 在 KOReader 工具菜单中打开“番茄小说（实验版）”。
2. 确认首先看到“我的本地书架”。
3. 选择“搜索或添加一本书”。
4. 输入书名、作者名，或番茄官网书籍链接。
5. 选中书籍后等待目录加载，再选择“继续阅读”。

官网有时会要求浏览器滑块验证。出现相关提示时，插件不会绕过验证；请稍后重试，或改用番茄官网书籍链接。首次打开未缓存章节需要联网，已经完整缓存的章节可离线打开。

## 安装成功的判断

- 工具菜单中出现“番茄小说（实验版）”。
- 打开后首先显示“我的本地书架”。
- 能看到扫码导入、搜索或添加、文件导入三个入口。
- 添加公开书籍后能显示目录；打开公开章节时正文无乱码。

## 常见问题

### 工具菜单里没有插件

先检查是否误放成双层目录。正确文件必须是 `koreader/plugins/fanqielite.koplugin/_meta.lua`，然后完整重启 KOReader。

### 提示网络、证书或设备时间错误

确认 Wi-Fi 可用，并让 Kindle 联网校准日期和时间后重试。失败不会删除现有书架或缓存。

### 搜索提示官方安全验证

这是番茄官网的访问限制，不是插件损坏。插件不会绕过验证；请稍后重试或输入官方书籍链接。

### 章节提示预览、登录或需要解锁

该章节没有向未登录网页提供完整公开正文。插件会拒绝保存预览或锁定内容，请在番茄官方客户端阅读该章节。

## 安全回退与卸载

升级后如需回退：先退出 KOReader，用电脑把 `koreader/plugins/fanqielite.koplugin` 替换为升级前备份，然后重新打开 KOReader。不要同时删除设置或缓存。

只卸载插件时，仅删除：

```text
koreader/plugins/fanqielite.koplugin
```

这不会自动删除 Kindle 书籍、KOReader、其他插件、Fanqie Lite 书架设置或章节缓存。完整数据清理请按插件“设置与数据 → 完全卸载与安全回退”中的路径逐项操作，不要删除整个 `koreader` 目录。
