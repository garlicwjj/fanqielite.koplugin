"use strict";

const assert = require("assert");
const exporter = require("../tools/export-bookshelf.js");

const shelf = {
    code: 0,
    data: {
        book_shelf_info: [
            { book_id: "7633875868615461950", book_type: 0 },
            { book_id: "7633875868615461950", book_type: 0 },
            { book_id: "7234567890123456789", book_type: 1 },
            { book_id: 7633875868615461950, book_type: 0 }
        ]
    }
};
const detail = {
    code: 0,
    data: {
        bookList: [{
            book_id: "7633875868615461950",
            book_name: " 测试\n书籍 ",
            author: "作者甲",
            thumb_url: "//p3-novel.byteimg.com/cover.jpg"
        }]
    }
};
const progress = {
    code: 0,
    data: [{
        book_id: "7633875868615461950",
        item_id: "10000000002",
        item_title: "第二章"
    }]
};

const output = exporter.buildExport(shelf, detail, progress, "2026-08-16T12:00:00Z");
assert.strictEqual(output.format, "fanqielite-bookshelf");
assert.strictEqual(output.version, 1);
assert.strictEqual(output.books.length, 1, "duplicates, unsupported types and unsafe numeric IDs must be skipped");
assert.strictEqual(output.books[0].title, "测试 书籍");
assert.strictEqual(output.books[0].cover_url, "https://p3-novel.byteimg.com/cover.jpg");
assert.strictEqual(output.books[0].current_chapter_id, "10000000002");
assert.strictEqual(output.books[0].current_chapter_title, "第二章");
assert.strictEqual(Object.prototype.hasOwnProperty.call(output.books[0], "cookie"), false);

assert.strictEqual(exporter.normalizeId("1234567890"), "1234567890");
assert.strictEqual(exporter.normalizeId(1234567890), "");
assert.strictEqual(exporter.normalizeCover("http://example.com/a.jpg"), "");
assert.strictEqual(exporter.normalizeCover("https://example.com/a b.jpg"), "");
assert.strictEqual(exporter.discoverUrl([
    { name: "https://fanqienovel.com/first" },
    { name: "https://fanqienovel.com/api/reader/book/progress?a=1" }
], "/api/reader/book/progress"), "https://fanqienovel.com/api/reader/book/progress?a=1");

assert.throws(() => exporter.buildExport({ code: -1, message: "请先登录" }, detail, progress), /读取官方书架失败/);
assert.throws(() => exporter.buildExport({ code: 0, data: { book_shelf_info: [] } }, detail, progress), /没有可导出/);

console.log("browser exporter tests passed");
