package.path = "./?.lua;./?/init.lua;" .. package.path

local Search = require("fanqielite.search")

local url, query = assert(Search.build_url("  三体 刘慈欣  "))
assert(query == "三体 刘慈欣")
assert(url:find("https://fanqienovel.com/api/author/search/search_book/v1?", 1, true) == 1)
assert(url:find("page_count=10", 1, true))
assert(url:find("page_index=0", 1, true))
assert(url:find("query_type=0", 1, true))
assert(url:find("query_word=%E4%B8%89%E4%BD%93%20%E5%88%98%E6%85%88%E6%AC%A3", 1, true))

local missing, missing_err = Search.build_url("   ")
assert(missing == nil and missing_err:find("书名或作者", 1, true))
local control, control_err = Search.build_url("标题\n伪造提示")
assert(control == nil and control_err:find("控制字符", 1, true))
local long, long_err = Search.build_url(string.rep("x", 241))
assert(long == nil and long_err:find("过长", 1, true))

local payload = {
    code = 0,
    data = {
        total_count = 3,
        search_book_data_list = {
            {
                book_id = "7633875868615461950",
                book_name = " 三体 I ",
                author = "刘慈欣",
                irrelevant_server_field = "ignored",
            },
            {
                book_id = "7334567890123456789",
                book_name = "三体：黑暗森林",
                author = "刘慈欣",
            },
            {
                book_id = "7633875868615461950",
                book_name = "重复结果",
                author = "",
            },
        },
    },
}
local results = assert(Search.parse(payload))
assert(#results == 2, "duplicate search result was not removed")
assert(results[1].id == "7633875868615461950")
assert(results[1].title == "三体 I")
assert(results[1].author == "刘慈欣")

local challenged, challenged_err = Search.parse({ code = -5 })
assert(challenged == nil and challenged_err:find("安全验证", 1, true))

local numeric_id = {
    code = 0,
    data = { search_book_data_list = {{
        book_id = 7633875868615461950,
        book_name = "精度已经丢失",
        author = "作者",
    }}},
}
local unsafe, unsafe_err = Search.parse(numeric_id)
assert(unsafe == nil and unsafe_err:find("格式异常", 1, true))

local malformed = {
    code = 0,
    data = { search_book_data_list = { [2] = {
        book_id = "7334567890123456789", book_name = "稀疏结果",
    }}},
}
local sparse, sparse_err = Search.parse(malformed)
assert(sparse == nil and sparse_err:find("连续数组", 1, true))

local too_many = { code = 0, data = { search_book_data_list = {} } }
for index = 1, 11 do
    too_many.data.search_book_data_list[index] = {
        book_id = tostring(7000000000000000000 + index),
        book_name = "结果 " .. tostring(index),
    }
end
local excessive, excessive_err = Search.parse(too_many)
assert(excessive == nil and excessive_err:find("数量异常", 1, true))

local empty, empty_err = Search.parse({ code = 0, data = { search_book_data_list = {} } })
assert(empty == nil and empty_err:find("没有找到", 1, true))

print("search tests passed")
