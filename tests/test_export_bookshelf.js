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
            { book_id: "7234567890123456789", book_type: 1 }
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
assert.strictEqual(output.books.length, 1, "duplicates and unsupported book types must be excluded");
assert.strictEqual(output.books[0].title, "测试 书籍");
assert.strictEqual(output.books[0].cover_url, "https://p3-novel.byteimg.com/cover.jpg");
assert.strictEqual(output.books[0].current_chapter_id, "10000000002");
assert.strictEqual(output.books[0].current_chapter_title, "第二章");
assert.strictEqual(Object.prototype.hasOwnProperty.call(output.books[0], "cookie"), false);

const canonicalProgressOutput = exporter.buildExport(shelf, detail, {
    code: 0,
    data: [{
        book_id: "7633875868615461950",
        item_id: "10000000003",
        origin_chapter_title: "第三章"
    }]
}, "2026-08-16T12:00:00Z");
assert.strictEqual(canonicalProgressOutput.books[0].current_chapter_id, "10000000003");
assert.strictEqual(canonicalProgressOutput.books[0].current_chapter_title, "第三章",
    "the current public ApiItemInfo chapter title field must be preserved");
assert.strictEqual(Object.prototype.hasOwnProperty.call(
    canonicalProgressOutput.books[0], "reading_position"), false,
"unverified public progress-rate fields must not be guessed into a KOReader position");
const publicTitleFallbackOutput = exporter.buildExport(shelf, detail, {
    code: 0,
    data: [{
        book_id: "7633875868615461950",
        item_id: "10000000004",
        title: "第四章",
        item_progress_rate: 75,
        page_progress_rate: 0.75
    }]
});
assert.strictEqual(publicTitleFallbackOutput.books[0].current_chapter_title, "第四章");
assert.strictEqual(Object.prototype.hasOwnProperty.call(
    publicTitleFallbackOutput.books[0], "reading_position"), false);
assert.throws(() => exporter.buildExport(shelf, detail, {
    code: 0,
    data: [null]
}), /阅读进度包含无效条目/,
"a malformed discovered progress item must not become a successful export");
assert.throws(() => exporter.buildExport(shelf, detail, {
    code: 0,
    data: [{ book_id: 7633875868615461950, item_id: "10000000003" }]
}), /阅读进度包含无效书籍 ID/,
"an unsafe numeric progress book ID must not disappear from a successful export");
assert.throws(() => exporter.buildExport(shelf, detail, {
    code: 0,
    data: [
        { book_id: "7633875868615461950", item_id: "10000000002" },
        { book_id: "7633875868615461950", item_id: "10000000003" }
    ]
}), /阅读进度包含重复书籍 ID/,
"ambiguous progress for an exported shelf book must not be silently overwritten");
assert.throws(() => exporter.buildExport(shelf, detail, {
    code: 0,
    data: [{ book_id: "7633875868615461950", item_id: 10000000003 }]
}), /阅读进度包含无效章节 ID/,
"a matching progress item with an unsafe numeric chapter ID must stop the export");

const unrelatedProgressOutput = exporter.buildExport(shelf, detail, {
    code: 0,
    data: [{
        book_id: "7334567890123456789",
        item_id: "10000000009",
        origin_chapter_title: credentialCanary
    }]
}, "2026-08-16T12:00:00Z");
assert.strictEqual(unrelatedProgressOutput.books.length, 1);
assert.strictEqual(JSON.stringify(unrelatedProgressOutput).includes(credentialCanary), false,
    "valid progress for a book outside the exported shelf must remain excluded");
assert.throws(() => exporter.buildExport(shelf, detail, {
    code: 0,
    data: Array.from({ length: 501 }, (_, index) => ({
        book_id: String(7000000000 + index),
        item_id: "10000000009"
    }))
}), /阅读进度数量异常/,
"an oversized global progress response must stop before indexing untrusted entries");

assert.throws(() => exporter.buildExport({
    code: 0,
    data: { book_shelf_info: [{ book_id: 7633875868615461950, book_type: 0 }] }
}, detail, progress), /无效书籍 ID/,
"a supported shelf item with an unsafe numeric ID must not disappear from a successful export");
assert.throws(() => exporter.buildExport({
    code: 0,
    data: { book_shelf_info: [{
        book_id: "7633875868615461950",
        book_type: { token: credentialCanary }
    }] }
}, detail, progress), (error) => {
    assert.strictEqual(error.message.includes(credentialCanary), false);
    return /未知书籍类型/.test(error.message);
}, "an unknown supported-type marker must not be silently treated as an excluded book");
assert.throws(() => exporter.buildExport({
    code: 0,
    data: { book_shelf_info: [
        { book_id: "7633875868615461950", book_type: 0 },
        { book_id: "7334567890123456789", book_type: 0 }
    ] }
}, detail, progress), /书籍信息不完整/,
"a shelf book missing from the detail response must not receive a placeholder title");
assert.throws(() => exporter.buildExport(shelf, {
    code: 0,
    data: { bookList: [{ book_id: "7633875868615461950", book_name: "\n\t" }] }
}, progress), /书名无效/,
"an empty cleaned title must not become a placeholder title");
assert.throws(() => exporter.buildExport(shelf, {
    code: 0,
    data: { bookList: {} }
}, progress), /书籍信息返回未知结构/,
"a malformed detail list must not become a successful incomplete export");
assert.throws(() => exporter.buildExport(shelf, {
    code: 0,
    data: { bookList: [detail.data.bookList[0], detail.data.bookList[0]] }
}, progress), /书籍信息与官方书架不一致/,
"duplicate detail records must not be silently collapsed");

const outputWithoutDiscoveredProgress = exporter.buildExport(
    shelf, detail, undefined, "2026-08-16T12:00:00Z");
assert.strictEqual(outputWithoutDiscoveredProgress.books.length, 1);
assert.strictEqual(Object.prototype.hasOwnProperty.call(
    outputWithoutDiscoveredProgress.books[0], "current_chapter_id"), false,
    "an undiscovered optional progress request must remain distinguishable from a failed request");
assert.throws(() => exporter.buildExport(
    shelf, detail, { code: 0, data: {} }), /阅读进度返回未知结构/,
    "malformed successful progress response must not become a successful incomplete export");
assert.throws(() => exporter.buildExport(
    shelf, detail, null), /读取阅读进度失败/,
    "null discovered progress response must not be mistaken for an undiscovered request");

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
const diagnostic = exporter.authorDiagnostics({ code: 0, data: { bookList: [
    { author: credentialCanary, author_info: { token: credentialCanary }, [credentialCanary]: credentialCanary },
    { author: null, authors: [credentialCanary] },
] } });
assert.strictEqual(JSON.stringify(diagnostic).includes(credentialCanary), false);
assert.deepStrictEqual(diagnostic.author_fields[0], { field: "author", types: { string: 1, null: 1 } });
assert.strictEqual(diagnostic.count, 2);
for (const suffix of ["", "v0/", "v1/", "v123/", "v:version/"]) {
    const url = "https://fanqienovel.com/reading/bookapi/bookshelf/info/" + suffix + "?from=page";
    assert.strictEqual(exporter.discoverShelfUrl([{ name: url }]), url);
}
for (const url of [
    "https://attacker.invalid/reading/bookapi/bookshelf/info/v0/",
    "https://fanqienovel.com.attacker.invalid/reading/bookapi/bookshelf/info/v0/",
    "https://user@fanqienovel.com/reading/bookapi/bookshelf/info/v0/",
    "http://fanqienovel.com/reading/bookapi/bookshelf/info/v0/",
    "https://fanqienovel.com/reading/bookapi/bookshelf/info/v0/extra",
    "https://fanqienovel.com/reading/bookapi/bookshelf/info/v0/#secret",
    "https://fanqienovel.com/reading/bookapi/bookshelf/info/v1000/",
    "https://fanqienovel.com/reading/bookapi/bookshelf/info/v:other/",
    "https://fanqienovel.com/reading/bookapi/bookshelf/add/v0/",
]) assert.strictEqual(exporter.discoverShelfUrl([{ name: url }]), "");
assert.strictEqual(exporter.discoverShelfUrl([]), "");
assert.strictEqual(exporter.normalizeId(1234567890), "");
assert.strictEqual(exporter.normalizeId("9".repeat(65)), "");
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
assert.throws(() => exporter.buildExport(
    shelf, detail, { code: -1, message: credentialCanary }), (error) => {
    assert.strictEqual(error.message.includes(credentialCanary), false);
    return /读取阅读进度失败/.test(error.message);
}, "failed discovered progress response must not become a successful incomplete export");
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

    const realSetTimeout = global.setTimeout;
    const realClearTimeout = global.clearTimeout;
    let expire;
    let cleared = 0;
    global.setTimeout = (callback, delay) => {
        assert.strictEqual(delay, 20000);
        expire = callback;
        return 123;
    };
    global.clearTimeout = (timer) => { assert.strictEqual(timer, 123); cleared += 1; };
    try {
        for (const stage of ["fetch", "body"]) {
            await rejectedWithoutCanary(exporter.readJson(
                "/api/book/simple/info", "/api/book/simple/info", { redirect: "follow" }, "读取书籍信息",
                async (_, options) => {
                    assert.strictEqual(options.redirect, "error");
                    const stall = () => new Promise((resolve, reject) => {
                        options.signal.addEventListener("abort", () => reject(new Error(credentialCanary)));
                        expire();
                    });
                    if (stage === "fetch") return stall();
                    return { ok: true, body: { getReader: () => ({ read: stall }) } };
                }
            ), /超时/);
        }
        assert.strictEqual(cleared, 2);
    } finally {
        global.setTimeout = realSetTimeout;
        global.clearTimeout = realClearTimeout;
    }

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
    let shelfResponse = shelf;
    let detailResponse = detail;
    let progressResponse = progress;
    try {
        global.location = { origin: "https://fanqienovel.com", pathname: "/bookshelf" };
        global.performance = { getEntriesByType: () => [
            { name: "https://attacker.invalid/reading/bookapi/bookshelf/info/?cookie=" + credentialCanary },
            { name: "https://fanqienovel.com/reading/bookapi/bookshelf/info/v:version/?from=page" },
            { name: "https://fanqienovel.com/api/reader/book/progress?from=page" }
        ] };
        global.fetch = async (url, options) => {
            requests.push({ url, options });
            if (url.includes("/bookshelf/info/")) return mockResponse(JSON.stringify(shelfResponse));
            if (url.includes("/api/book/simple/info")) return mockResponse(JSON.stringify(detailResponse));
            if (url.includes("/api/reader/book/progress")) {
                return mockResponse(JSON.stringify(progressResponse));
            }
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
        assert.strictEqual(new URL(requests[0].url).pathname, "/reading/bookapi/bookshelf/info/v:version/");
        assert.strictEqual(requests.every((request) => new URL(request.url).origin === "https://fanqienovel.com"), true);
        assert.strictEqual(requests.every((request) => request.options.credentials === "include"), true);
        assert.strictEqual(requests.every((request) => request.options.redirect === "error"), true);
        assert.strictEqual(requests.every((request) => request.options.signal.aborted), true);
        assert.match(successAlert, /已导出 1 本书/);

        requests.length = 0;
        downloadedBlob = undefined;
        downloadName = undefined;
        progressResponse = { code: -1, message: credentialCanary };
        await rejectedWithoutCanary(exporter.run(), /读取阅读进度失败/);
        assert.strictEqual(requests.length, 3,
            "expired progress session did not stop at the discovered progress request");
        assert.strictEqual(downloadedBlob, undefined,
            "failed progress request created an incomplete download blob");
        assert.strictEqual(downloadName, undefined,
            "failed progress request clicked a download link");

        progressResponse = {
            code: 0,
            data: [{ book_id: "7633875868615461950", item_id: 10000000003 }]
        };
        requests.length = 0;
        downloadedBlob = undefined;
        downloadName = undefined;
        await rejectedWithoutCanary(exporter.run(), /阅读进度包含无效章节 ID/);
        assert.strictEqual(requests.length, 3,
            "malformed progress did not stop immediately after the discovered progress request");
        assert.strictEqual(downloadedBlob, undefined,
            "malformed progress created an incomplete download blob");
        assert.strictEqual(downloadName, undefined,
            "malformed progress clicked a download link");

        progressResponse = progress;
        shelfResponse = {
            code: 0,
            data: { book_shelf_info: [{ book_id: 7633875868615461950, book_type: 0 }] }
        };
        requests.length = 0;
        downloadedBlob = undefined;
        downloadName = undefined;
        await rejectedWithoutCanary(exporter.run(), /无效书籍 ID/);
        assert.strictEqual(requests.length, 1,
            "invalid supported shelf ID was not rejected before the detail request");
        assert.strictEqual(downloadedBlob, undefined,
            "invalid supported shelf ID created an incomplete download blob");
        assert.strictEqual(downloadName, undefined,
            "invalid supported shelf ID clicked a download link");

        shelfResponse = shelf;
        detailResponse = { code: 0, data: { bookList: [] } };
        requests.length = 0;
        downloadedBlob = undefined;
        downloadName = undefined;
        await rejectedWithoutCanary(exporter.run(), /书籍信息不完整/);
        assert.strictEqual(requests.length, 2,
            "missing detail response did not stop before requesting optional progress");
        assert.strictEqual(downloadedBlob, undefined,
            "missing detail response created an incomplete download blob");
        assert.strictEqual(downloadName, undefined,
            "missing detail response clicked a download link");

        detailResponse = detail;
        progressResponse = progress;
        requests.length = 0;
        downloadedBlob = undefined;
        downloadName = undefined;
        const diagnosticResult = await exporter.run({ diagnostic: true });
        assert.strictEqual(diagnosticResult.count, 1);
        assert.strictEqual(requests.length, 2, "diagnostic must not request progress");
        assert.strictEqual(downloadedBlob, undefined, "diagnostic must not create a download");
        assert.strictEqual(downloadName, undefined);
        assert.strictEqual(successAlert.includes(credentialCanary), false);
        assert.match(successAlert, /未导出文件/);
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
    assert.match(source, /FANQIELITE_AUTHOR_DIAGNOSTIC\s*===\s*true/,
        "browser diagnostic mode must require an explicit exact boolean opt-in");
    assert.strictEqual(source.includes("番茄书籍 "), false,
        "browser exporter must not manufacture placeholder titles for missing details");
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
