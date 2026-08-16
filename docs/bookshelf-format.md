# 书架 JSON 文件格式（版本 1）

文件必须命名为 `fanqielite-bookshelf.json`，使用 UTF-8 编码，且不超过 256 KB。插件一次最多接受 500 本书。

```json
{
  "format": "fanqielite-bookshelf",
  "version": 1,
  "exported_at": "2026-08-16T12:00:00Z",
  "books": [
    {
      "id": "7633875868615461950",
      "title": "示例书名",
      "author": "示例作者",
      "cover_url": "https://example.invalid/cover.jpg",
      "current_chapter_id": "10000000002",
      "current_chapter_title": "第二章",
      "reading_position": 0.5
    }
  ]
}
```

`id` 必须是至少 10 位的数字字符串，不能写成 JSON 数字，否则 19 位 ID 可能丢失精度。`reading_position` 可省略；存在时必须是 0 到 1 的数字。除 `id` 和 `title` 外，其余书籍字段均可省略。

插件使用严格字段白名单。文件中不得包含 Cookie、Token、session、CSRF、手机号、密码、授权头或其他账号凭证；出现凭证字段或未知字段时，整个文件都会被拒绝，现有书架不会改变。

导入只建立本地书架记录，不会联网，也不会上传数据。新导入的书籍首次打开时，用户需要主动联网获取官方目录。封面地址目前只保存、不下载。

## 从浏览器导出

仓库中的 [`tools/export-bookshelf.js`](../tools/export-bookshelf.js) 只能在 `https://fanqienovel.com/bookshelf` 页面执行。它复用浏览器当前已经登录的会话，向该页面正在使用的番茄官方接口发起只读请求，但不会读取、显示或写入浏览器 Cookie。

脚本只生成本页格式白名单中的书籍数据，不包含 Cookie、Token、手机号或请求头。使用步骤会在浏览器端实测通过后补充；当前仍属于开发验证工具，不建议普通用户使用。
