"use strict";

const assert = require("assert");
const fs = require("fs");
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
const credentialCanary = "COOKIE_SESSION_TOKEN_CANARY_8f7c";

const output = exporter.buildExport(shelf, detail, progress, "2026-08-16T12:00:00Z");
assert.strictEqual(output.format, "fanqielite-bookshelf");
assert.strictEqual(output.version, 1);
assert.strictEqual(output.books.length, 1, "duplicates, unsupported types and unsafe numeric IDs must be skipped");
assert.strictEqual(output.books[0].title, "测试 书籍");
assert.strictEqual(output.books[0].cover_url, "https://p3-novel.byteimg.com/cover.jpg");
assert.strictEqual(output.books[0].current_chapter_id, "10000000002");
assert.strictEqual(output.books[0].current_chapter_title, "第二章");
assert.strictEqual(Object.prototype.hasOwnProperty.call(output.books[0], "cookie"), false);

const privateOutput = exporter.buildExport({
    code: 0,
    cookie: credentialCanary,
    data: { book_shelf_info: [{ book_id: "7633875868615461950", book_type: 0, token: credentialCanary }] }
}, {
    code: 0,
    authorization: credentialCanary,
    data: { bookList: [{
        book_id: "7633875868615461950",
        book_name: "安全书名",
        sessionid: credentialCanary,
        phone: credentialCanary
    }] }
}, {
    code: 0,
    data: [{ book_id: "7633875868615461950", item_id: "10000000002", csrf_token: credentialCanary }]
}, "2026-08-16T12:00:00Z");
assert.strictEqual(JSON.stringify(privateOutput).includes(credentialCanary), false,
    "private response fields must not enter the downloaded JSON");

assert.strictEqual(exporter.normalizeId("1234567890"), "1234567890");
assert.strictEqual(exporter.normalizeId(1234567890), "");
assert.strictEqual(exporter.normalizeCover("http://example.com/a.jpg"), "");
assert.strictEqual(exporter.normalizeCover("https://example.com/a b.jpg"), "");
assert.strictEqual(exporter.normalizeCover("https://user:" + credentialCanary + "@example.com/a.jpg"), "");
assert.strictEqual(exporter.normalizeCover("https://example.com/a.jpg#" + credentialCanary), "");
assert.strictEqual(exporter.discoverUrl([
    { name: "https://fanqienovel.com/first" },
    { name: "https://attacker.invalid/api/reader/book/progress?a=1" },
    { name: "https://fanqienovel.com/api/reader/book/progress/extra?a=1" },
    { name: "https://fanqienovel.com/api/reader/book/progress?a=1" }
], "/api/reader/book/progress"), "https://fanqienovel.com/api/reader/book/progress?a=1");
assert.strictEqual(exporter.officialUrl("https://attacker.invalid/api/book/simple/info", "/api/book/simple/info"), "");
assert.strictEqual(exporter.officialUrl("//attacker.invalid/api/book/simple/info", "/api/book/simple/info"), "");
assert.strictEqual(exporter.officialUrl("/api/book/simple/info#secret", "/api/book/simple/info"), "");

let safeStageError;
assert.throws(() => exporter.buildExport({ code: -1, message: credentialCanary }, detail, progress), (error) => {
    safeStageError = error;
    assert.strictEqual(error.message.includes(credentialCanary), false);
    return /读取官方书架失败/.test(error.message);
});
assert.throws(() => exporter.buildExport({ code: 0, data: { book_shelf_info: [] } }, detail, progress), /没有可导出/);

function mockResponse(text, options = {}) {
    const bytes = new TextEncoder().encode(text);
    let sent = false;
    return {
        ok: options.ok !== false,
        status: options.status === undefined ? 200 : options.status,
        headers: {
            get(name) {
                return name.toLowerCase() === "content-length" && options.contentLength !== undefined
                    ? String(options.contentLength) : null;
            }
        },
        body: {
            getReader() {
                return {
                    async read() {
                        if (options.readError) throw new Error(credentialCanary);
                        if (sent) return { done: true };
                        sent = true;
                        return { done: false, value: bytes };
                    },
                    async cancel() {}
                };
            }
        }
    };
}

async function rejectedWithoutCanary(promise, pattern) {
    await assert.rejects(promise, (error) => {
        assert.strictEqual(String(error.message).includes(credentialCanary), false,
            "raw response or exception content must not enter the error");
        return pattern.test(error.message);
    });
}

(async () => {
    const parsed = await exporter.readJson("/api/book/simple/info", "/api/book/simple/info", {}, "读取书籍信息",
        async () => mockResponse('{"code":0,"data":{}}'));
    assert.strictEqual(parsed.code, 0);

    let crossOriginFetches = 0;
    await rejectedWithoutCanary(exporter.readJson(
        "https://attacker.invalid/api/book/simple/info", "/api/book/simple/info", {}, "读取书籍信息",
        async () => { crossOriginFetches += 1; return mockResponse("{}"); }
    ), /请求地址无效/);
    assert.strictEqual(crossOriginFetches, 0, "cross-origin URL must fail before fetch");

    await rejectedWithoutCanary(exporter.readJson(
        "/api/book/simple/info", "/api/book/simple/info", {}, "读取书籍信息",
        async () => { throw new Error(credentialCanary); }
    ), /网络请求失败/);
    await rejectedWithoutCanary(exporter.readJson(
        "/api/book/simple/info", "/api/book/simple/info", {}, "读取书籍信息",
        async () => mockResponse(credentialCanary, { ok: false, status: credentialCanary })
    ), /请求失败/);
    await rejectedWithoutCanary(exporter.readJson(
        "/api/book/simple/info", "/api/book/simple/info", {}, "读取书籍信息",
        async () => mockResponse(credentialCanary)
    ), /没有返回有效 JSON/);
    await rejectedWithoutCanary(exporter.readJson(
        "/api/book/simple/info", "/api/book/simple/info", {}, "读取书籍信息",
        async () => mockResponse("{}", { readError: true })
    ), /响应无法安全读取/);
    await rejectedWithoutCanary(exporter.readJson(
        "/api/book/simple/info", "/api/book/simple/info", {}, "读取书籍信息",
        async () => mockResponse("{}", { contentLength: 2 * 1024 * 1024 + 1 })
    ), /响应过大/);
    await rejectedWithoutCanary(exporter.readJson(
        "/api/book/simple/info", "/api/book/simple/info", {}, "读取书籍信息",
        async () => mockResponse("x".repeat(2 * 1024 * 1024 + 1))
    ), /响应过大/);

    const originalGlobals = {
        location: global.location,
        performance: global.performance,
        fetch: global.fetch,
        document: global.document,
        alert: global.alert,
        createObjectURL: URL.createObjectURL,
        revokeObjectURL: URL.revokeObjectURL
    };
    const requests = [];
    let downloadedBlob;
    let downloadName;
    let successAlert = "";
    try {
        global.location = { origin: "https://fanqienovel.com", pathname: "/bookshelf" };
        global.performance = { getEntriesByType: () => [
            { name: "https://attacker.invalid/reading/bookapi/bookshelf/info/?cookie=" + credentialCanary },
            { name: "https://fanqienovel.com/reading/bookapi/bookshelf/info/?from=page" },
            { name: "https://fanqienovel.com/api/reader/book/progress?from=page" }
        ] };
        global.fetch = async (url, options) => {
            requests.push({ url, options });
            if (url.includes("/bookshelf/info/")) return mockResponse(JSON.stringify(shelf));
            if (url.includes("/api/book/simple/info")) return mockResponse(JSON.stringify(detail));
            if (url.includes("/api/reader/book/progress")) return mockResponse(JSON.stringify(progress));
            throw new Error(credentialCanary);
        };
        global.document = {
            body: { appendChild() {} },
            createElement() {
                return {
                    href: "",
                    download: "",
                    click() { downloadName = this.download; },
                    remove() {}
                };
            }
        };
        global.alert = (message) => { successAlert = message; };
        URL.createObjectURL = (blob) => { downloadedBlob = blob; return "blob:test"; };
        URL.revokeObjectURL = () => {};

        await exporter.run();
        const downloadedText = await downloadedBlob.text();
        const downloaded = JSON.parse(downloadedText);
        assert.strictEqual(downloadName, "fanqielite-bookshelf.json");
        assert.strictEqual(downloaded.books.length, 1);
        assert.strictEqual(downloaded.books[0].title, "测试 书籍");
        assert.strictEqual(downloadedText.includes(credentialCanary), false);
        assert.strictEqual(requests.length, 3);
        assert.strictEqual(requests.every((request) => new URL(request.url).origin === "https://fanqienovel.com"), true);
        assert.strictEqual(requests.every((request) => request.options.credentials === "include"), true);
        assert.match(successAlert, /已导出 1 本书/);
    } finally {
        global.location = originalGlobals.location;
        global.performance = originalGlobals.performance;
        global.fetch = originalGlobals.fetch;
        global.document = originalGlobals.document;
        global.alert = originalGlobals.alert;
        URL.createObjectURL = originalGlobals.createObjectURL;
        URL.revokeObjectURL = originalGlobals.revokeObjectURL;
    }

    assert.match(exporter.publicFailureMessage(safeStageError), /读取官方书架失败/);
    const untrustedFailure = exporter.publicFailureMessage(new Error(credentialCanary));
    assert.strictEqual(untrustedFailure.includes(credentialCanary), false);
    assert.strictEqual(/error|message|String\s*\(/.test(untrustedFailure), false);
    const source = fs.readFileSync(require.resolve("../tools/export-bookshelf.js"), "utf8");
    [
        /console\s*\./,
        /document\s*\.\s*cookie/,
        /localStorage/,
        /sessionStorage/,
        /payload\s*\.\s*message/,
        /response\s*\.\s*text\s*\(/,
        /String\s*\(\s*error/
    ].forEach((pattern) => assert.strictEqual(pattern.test(source), false,
        "browser exporter must not read credentials, log, or stringify raw failures: " + pattern));
    console.log("browser exporter tests passed");
})().catch((error) => {
    process.stderr.write("browser exporter tests failed\n");
    process.exitCode = 1;
});
