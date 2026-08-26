local function synthetic_body(characters)
    return "<p>" .. string.rep("公开测试文字", math.ceil(characters / 6)) .. "</p>"
end

return {
    books = {
        {
            name = "page metadata",
            state = { page = {
                bookId = "70000000001", bookName = " 测试书籍 ", author = " 测试作者 ",
            } },
            expected_id = "70000000001",
            expected_title = "测试书籍",
        },
        {
            name = "fallback request id",
            state = { page = { bookName = "缺少页面 ID" } },
            request_id = "70000000002",
            expected_id = "70000000002",
        },
        {
            name = "mismatched book id",
            state = { page = { bookId = "70000000003", bookName = "错误书籍" } },
            request_id = "70000000004",
            error_contains = "不一致",
        },
        {
            name = "numeric book id",
            state = { page = { bookId = 70000000005, bookName = "数值 ID" } },
            error_contains = "ID 无效",
        },
        {
            name = "object book title",
            state = { page = { bookId = "70000000006", bookName = {} } },
            error_contains = "书名格式无效",
        },
        {
            name = "object book author",
            state = { page = { bookId = "70000000007", bookName = "合法书名", author = {} } },
            error_contains = "作者格式无效",
        },
    },
    directories = {
        {
            name = "volume objects",
            payload = { data = { chapterListWithVolume = {
                { chapterList = {
                    { itemId = "71000000001", title = "第一章", index = 1 },
                    { itemId = "71000000002", title = "第二章", index = 2 },
                } },
            } } },
            expected_ids = { "71000000001", "71000000002" },
        },
        {
            name = "direct volume arrays",
            payload = { data = { chapterListWithVolume = {
                { { itemId = "71000000003", title = "第三章" } },
                { { itemId = "71000000004", title = "第四章" } },
            } } },
            expected_ids = { "71000000003", "71000000004" },
        },
        {
            name = "flat list alternate keys",
            payload = { data = { chapterList = {
                { item_id = "71000000005", title = "第五章", order = 5 },
            } } },
            expected_ids = { "71000000005" },
        },
        {
            name = "id-only fallback",
            payload = { data = { allItemIds = { "71000000006", "71000000007" } } },
            expected_ids = { "71000000006", "71000000007" },
        },
        {
            name = "duplicate chapter ids",
            payload = { data = { chapterList = {
                { itemId = "71000000008", title = "第八章" },
                { itemId = "71000000008", title = "重复章节" },
            } } },
            error_contains = "重复",
        },
        {
            name = "partially malformed list",
            payload = { data = { chapterList = {
                { itemId = "71000000009", title = "合法章节" },
                { itemId = "../invalid", title = "非法章节" },
            } } },
            error_contains = "无效",
        },
        {
            name = "wrong flat list type",
            payload = { data = { chapterList = "not-a-list" } },
            error_contains = "结构无效",
        },
        {
            name = "numeric chapter id",
            payload = { data = { chapterList = {
                { itemId = 71000000010, title = "数值 ID" },
            } } },
            error_contains = "章节 ID",
        },
        {
            name = "object chapter title",
            payload = { data = { chapterList = {
                { itemId = "71000000011", title = {} },
            } } },
            error_contains = "章节标题",
        },
        {
            name = "object chapter index",
            payload = { data = { chapterList = {
                { itemId = "71000000012", title = "合法标题", index = {} },
            } } },
            error_contains = "章节序号",
        },
    },
    chapters = {
        {
            name = "public full text",
            item_id = "72000000001",
            chapter = {
                itemId = "72000000001", title = "公开章节",
                content = synthetic_body(600), chapterWordNumber = 600,
                needPay = false, isChapterLock = false,
            },
            expected_title = "公开章节",
        },
        {
            name = "short preview",
            item_id = "72000000002",
            chapter = {
                itemId = "72000000002", title = "短预览",
                content = synthetic_body(180), chapterWordNumber = 180,
            },
            error_contains = "预览",
        },
        {
            name = "locked chapter",
            item_id = "72000000003",
            chapter = {
                itemId = "72000000003", title = "锁定章节",
                content = synthetic_body(600), chapterWordNumber = 600, needPay = true,
            },
            error_contains = "解锁",
        },
        {
            name = "mismatched chapter id",
            item_id = "72000000005",
            chapter = {
                itemId = "72000000004", title = "错误章节",
                content = synthetic_body(600), chapterWordNumber = 600,
            },
            error_contains = "不一致",
        },
        {
            name = "invalid numeric entity",
            item_id = "72000000006",
            chapter = {
                itemId = "72000000006", title = "非法实体",
                content = synthetic_body(600) .. "<p>&#55296;</p>", chapterWordNumber = 600,
            },
            error_contains = "字符实体",
        },
        {
            name = "invalid hexadecimal entity",
            item_id = "72000000009",
            chapter = {
                itemId = "72000000009", title = "非法十六进制实体",
                content = synthetic_body(600) .. "<p>&#xD800;</p>", chapterWordNumber = 600,
            },
            error_contains = "字符实体",
        },
        {
            name = "valid numeric entities",
            item_id = "72000000010",
            chapter = {
                itemId = "72000000010", title = "合法字符实体",
                content = synthetic_body(600) .. "<p>&#20013;&#x6587;&#58344;</p>", chapterWordNumber = 600,
            },
            expected_contains = "中文D",
            expected_pua = 1,
        },
        {
            name = "escaped numeric entity stays literal",
            item_id = "72000000011",
            chapter = {
                itemId = "72000000011", title = "转义实体文本",
                content = synthetic_body(600) .. "<p>&amp;#55296;</p>", chapterWordNumber = 600,
            },
            expected_contains = "&#55296;",
        },
        {
            name = "unknown pua entity",
            item_id = "72000000007",
            chapter = {
                itemId = "72000000007", title = "未知字符实体",
                content = synthetic_body(600) .. "<p>&#57344;</p>", chapterWordNumber = 600,
            },
            error_contains = "字符映射",
        },
        {
            name = "missing chapter data",
            item_id = "72000000008",
            missing_reader = true,
            error_contains = "没有章节数据",
        },
        {
            name = "numeric chapter item id",
            item_id = "72000000012",
            chapter = {
                itemId = 72000000012, title = "数值 ID",
                content = synthetic_body(600), chapterWordNumber = 600,
            },
            error_contains = "章节 ID",
        },
        {
            name = "object chapter title",
            item_id = "72000000013",
            chapter = {
                itemId = "72000000013", title = {},
                content = synthetic_body(600), chapterWordNumber = 600,
            },
            error_contains = "章节标题",
        },
        {
            name = "object chapter content",
            item_id = "72000000014",
            chapter = {
                itemId = "72000000014", title = "正文类型变化",
                content = {}, chapterWordNumber = 600,
            },
            error_contains = "正文格式",
        },
        {
            name = "unknown paywall state",
            item_id = "72000000015",
            chapter = {
                itemId = "72000000015", title = "未知权限",
                content = synthetic_body(600), chapterWordNumber = 600, needPay = {},
            },
            error_contains = "权限状态",
        },
        {
            name = "unknown lock state",
            item_id = "72000000017",
            chapter = {
                itemId = "72000000017", title = "未知锁定状态",
                content = synthetic_body(600), chapterWordNumber = 600, isChapterLock = 2,
            },
            error_contains = "权限状态",
        },
        {
            name = "object word count",
            item_id = "72000000016",
            chapter = {
                itemId = "72000000016", title = "字数类型变化",
                content = synthetic_body(600), chapterWordNumber = {},
            },
            error_contains = "字数格式",
        },
    },
}
