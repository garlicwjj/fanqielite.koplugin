(function (root, factory) {
    "use strict";
    var api = factory();
    if (typeof module === "object" && module.exports) {
        module.exports = api;
    } else {
        api.run().catch(function (error) {
            root.alert("Fanqie Lite 导出失败：\n" + String(error && error.message || error));
        });
    }
}(typeof window !== "undefined" ? window : this, function () {
    "use strict";

    var MAX_BOOKS = 500;
    var MAX_BYTES = 256 * 1024;
    var FILENAME = "fanqielite-bookshelf.json";

    function cleanText(value, maximum) {
        if (typeof value !== "string") return "";
        var cleaned = value.replace(/[\x00-\x1f\x7f]/g, " ").trim();
        return Array.from(cleaned).slice(0, maximum).join("");
    }

    function normalizeId(value) {
        return typeof value === "string" && /^\d{10,}$/.test(value) ? value : "";
    }

    function normalizeCover(value) {
        if (typeof value !== "string") return "";
        if (value.indexOf("//") === 0) value = "https:" + value;
        if (!/^https:\/\//.test(value) || value.length > 2048 || /[\x00-\x20\x7f]/.test(value)) return "";
        return value;
    }

    function responseData(payload, label) {
        if (!payload || typeof payload !== "object" || payload.code !== 0) {
            throw new Error(label + "失败：" + cleanText(payload && payload.message, 100));
        }
        return payload.data || {};
    }

    function buildExport(shelfPayload, detailPayload, progressPayload, exportedAt) {
        var shelfData = responseData(shelfPayload, "读取官方书架");
        var detailData = responseData(detailPayload, "读取书籍信息");
        var shelf = Array.isArray(shelfData.book_shelf_info) ? shelfData.book_shelf_info : [];
        var details = Array.isArray(detailData.bookList) ? detailData.bookList
            : (Array.isArray(detailData.book_list) ? detailData.book_list : []);
        var progress = progressPayload && progressPayload.code === 0 && Array.isArray(progressPayload.data)
            ? progressPayload.data : [];
        if (shelf.length > MAX_BOOKS) throw new Error("单次最多导出 500 本书");

        var detailById = {};
        details.forEach(function (item) {
            var id = normalizeId(item && item.book_id);
            if (id) detailById[id] = item;
        });
        var progressById = {};
        progress.forEach(function (item) {
            var id = normalizeId(item && item.book_id);
            if (id) progressById[id] = item;
        });

        var seen = {};
        var books = [];
        shelf.forEach(function (item) {
            if (item && item.book_type !== undefined && Number(item.book_type) !== 0) return;
            var id = normalizeId(item && item.book_id);
            if (!id || seen[id]) return;
            seen[id] = true;
            var detail = detailById[id] || {};
            var current = progressById[id] || {};
            var book = {
                id: id,
                title: cleanText(detail.book_name, 100) || ("番茄书籍 " + id)
            };
            var author = cleanText(detail.author || detail.author_name, 50);
            var cover = normalizeCover(detail.thumb_url || detail.thumb_uri);
            var chapterId = normalizeId(current.item_id);
            var chapterTitle = cleanText(current.item_title || current.chapter_title, 100);
            if (author) book.author = author;
            if (cover) book.cover_url = cover;
            if (chapterId) book.current_chapter_id = chapterId;
            if (chapterId && chapterTitle) book.current_chapter_title = chapterTitle;
            books.push(book);
        });
        if (!books.length) throw new Error("官方书架中没有可导出的小说，请确认已经登录并打开书架页面");
        return {
            format: "fanqielite-bookshelf",
            version: 1,
            exported_at: exportedAt || new Date().toISOString(),
            books: books
        };
    }

    function discoverUrl(entries, fragment) {
        for (var index = entries.length - 1; index >= 0; index -= 1) {
            var name = entries[index] && entries[index].name;
            if (typeof name === "string" && name.indexOf(fragment) >= 0) return name;
        }
        return "";
    }

    function jsonSize(text) {
        return new TextEncoder().encode(text).length;
    }

    async function readJson(url, options, label) {
        var response = await fetch(url, options || { credentials: "include" });
        var text = await response.text();
        if (text.length > 2 * 1024 * 1024) throw new Error(label + "响应过大，已停止导出");
        if (!response.ok) throw new Error(label + "返回 HTTP " + response.status);
        try { return JSON.parse(text); }
        catch (_) { throw new Error(label + "没有返回有效 JSON"); }
    }

    async function run() {
        if (location.origin !== "https://fanqienovel.com" || location.pathname.indexOf("/bookshelf") !== 0) {
            throw new Error("请先在 https://fanqienovel.com/bookshelf 登录并打开书架页面");
        }
        var entries = performance.getEntriesByType("resource");
        var shelfUrl = discoverUrl(entries, "/reading/bookapi/bookshelf/info/");
        if (!shelfUrl) throw new Error("没有找到官方书架请求，请刷新页面、等待书架显示后再运行");

        var shelfPayload = await readJson(shelfUrl, { credentials: "include" }, "读取官方书架");
        var shelfData = responseData(shelfPayload, "读取官方书架");
        var shelf = Array.isArray(shelfData.book_shelf_info) ? shelfData.book_shelf_info : [];
        var ids = [];
        var seen = {};
        shelf.forEach(function (item) {
            var id = normalizeId(item && item.book_id);
            if (id && !seen[id] && (item.book_type === undefined || Number(item.book_type) === 0)) {
                seen[id] = true;
                ids.push(id);
            }
        });
        if (!ids.length) throw new Error("官方书架中没有可导出的小说");
        if (ids.length > MAX_BOOKS) throw new Error("单次最多导出 500 本书");

        var detailPayload = await readJson("/api/book/simple/info", {
            method: "POST",
            credentials: "include",
            headers: { "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({ book_ids: ids })
        }, "读取书籍信息");
        var progressUrl = discoverUrl(entries, "/api/reader/book/progress");
        var progressPayload = progressUrl
            ? await readJson(progressUrl, { credentials: "include" }, "读取阅读进度")
            : { code: 0, data: [] };
        var output = buildExport(shelfPayload, detailPayload, progressPayload);
        var text = JSON.stringify(output, null, 2);
        if (jsonSize(text) > MAX_BYTES) {
            output.books.forEach(function (book) { delete book.cover_url; });
            text = JSON.stringify(output, null, 2);
        }
        if (jsonSize(text) > MAX_BYTES) throw new Error("生成文件超过 256 KB，请减少书架数量后重试");

        var blob = new Blob([text], { type: "application/json;charset=utf-8" });
        var url = URL.createObjectURL(blob);
        var link = document.createElement("a");
        link.href = url;
        link.download = FILENAME;
        document.body.appendChild(link);
        link.click();
        link.remove();
        URL.revokeObjectURL(url);
        alert("已导出 " + output.books.length + " 本书。\n\n文件不包含 Cookie、Token、手机号或登录凭证。请把 "
            + FILENAME + " 复制到 Kindle，再从 Fanqie Lite 中导入。");
    }

    return {
        buildExport: buildExport,
        cleanText: cleanText,
        discoverUrl: discoverUrl,
        normalizeCover: normalizeCover,
        normalizeId: normalizeId,
        run: run
    };
}));
