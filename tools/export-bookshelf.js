(function (root, factory) {
    "use strict";
    var api = factory();
    if (typeof module === "object" && module.exports) {
        module.exports = api;
    } else {
        api.run().catch(function (error) {
            root.alert(api.publicFailureMessage(error));
        });
    }
}(typeof window !== "undefined" ? window : this, function () {
    "use strict";

    var MAX_BOOKS = 500;
    var MAX_BYTES = 256 * 1024;
    var MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
    var FILENAME = "fanqielite-bookshelf.json";
    var OFFICIAL_ORIGIN = "https://fanqienovel.com";
    var SAFE_ERRORS = new WeakSet();

    function safeError(message) {
        var error = new Error(message);
        SAFE_ERRORS.add(error);
        return error;
    }

    function publicFailureMessage(error) {
        var detail = error && SAFE_ERRORS.has(error) ? "\n\n" + error.message : "";
        return "Fanqie Lite 导出失败。" + detail
            + "\n\n请刷新官方书架页面后重试；仍然失败请停止使用当前原型。";
    }

    function cleanText(value, maximum) {
        if (typeof value !== "string") return "";
        var cleaned = value.replace(/[\x00-\x1f\x7f]/g, " ").trim();
        return Array.from(cleaned).slice(0, maximum).join("");
    }

    function normalizeId(value) {
        return typeof value === "string" && /^\d{10,64}$/.test(value) ? value : "";
    }

    function normalizeCover(value) {
        if (typeof value !== "string") return "";
        if (value.indexOf("//") === 0) value = "https:" + value;
        if (value.length > 2048 || /[\x00-\x20\x7f]/.test(value)) return "";
        var parsed;
        try { parsed = new URL(value); }
        catch (_) { return ""; }
        if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.hash) return "";
        return parsed.href;
    }

    function responseData(payload, label) {
        if (!payload || typeof payload !== "object" || payload.code !== 0) {
            throw safeError(label + "失败，已停止导出");
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
        if (shelf.length > MAX_BOOKS) throw safeError("单次最多导出 500 本书");

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
        if (!books.length) throw safeError("官方书架中没有可导出的小说，请确认已经登录并打开书架页面");
        return {
            format: "fanqielite-bookshelf",
            version: 1,
            exported_at: exportedAt || new Date().toISOString(),
            books: books
        };
    }

    function officialUrl(value, expectedPath) {
        var parsed;
        try { parsed = new URL(value, OFFICIAL_ORIGIN); }
        catch (_) { return ""; }
        if (parsed.origin !== OFFICIAL_ORIGIN || parsed.pathname !== expectedPath
                || parsed.username || parsed.password || parsed.hash) return "";
        return parsed.href;
    }

    function discoverUrl(entries, expectedPath) {
        for (var index = entries.length - 1; index >= 0; index -= 1) {
            var name = entries[index] && entries[index].name;
            var url = typeof name === "string" ? officialUrl(name, expectedPath) : "";
            if (url) return url;
        }
        return "";
    }

    function jsonSize(text) {
        return new TextEncoder().encode(text).length;
    }

    async function responseText(response, label) {
        var declared = response.headers && response.headers.get
            ? Number(response.headers.get("Content-Length")) : NaN;
        if (Number.isFinite(declared) && declared > MAX_RESPONSE_BYTES) {
            throw safeError(label + "响应过大，已停止导出");
        }
        if (!response.body || typeof response.body.getReader !== "function") {
            throw safeError(label + "响应无法安全读取，已停止导出");
        }
        var reader = response.body.getReader();
        var decoder = new TextDecoder("utf-8", { fatal: true });
        var size = 0;
        var text = "";
        try {
            while (true) {
                var part = await reader.read();
                if (part.done) break;
                if (!(part.value instanceof Uint8Array)) {
                    throw safeError(label + "响应无法安全读取，已停止导出");
                }
                size += part.value.byteLength;
                if (size > MAX_RESPONSE_BYTES) {
                    if (typeof reader.cancel === "function") await reader.cancel();
                    throw safeError(label + "响应过大，已停止导出");
                }
                text += decoder.decode(part.value, { stream: true });
            }
            return text + decoder.decode();
        } catch (error) {
            if (error && SAFE_ERRORS.has(error)) throw error;
            throw safeError(label + "响应无法安全读取，已停止导出");
        }
    }

    async function readJson(url, expectedPath, options, label, fetcher) {
        var requestUrl = officialUrl(url, expectedPath);
        if (!requestUrl) throw safeError(label + "请求地址无效，已停止导出");
        var response;
        try { response = await (fetcher || fetch)(requestUrl, options || { credentials: "include" }); }
        catch (_) { throw safeError(label + "网络请求失败，已停止导出"); }
        if (!response || response.ok !== true) {
            var status = Number(response && response.status);
            var suffix = Number.isInteger(status) && status >= 100 && status <= 599
                ? "（HTTP " + status + "）" : "";
            throw safeError(label + "请求失败" + suffix + "，已停止导出");
        }
        var text = await responseText(response, label);
        try { return JSON.parse(text); }
        catch (_) { throw safeError(label + "没有返回有效 JSON，已停止导出"); }
    }

    async function run() {
        if (location.origin !== OFFICIAL_ORIGIN
                || (location.pathname !== "/bookshelf" && location.pathname !== "/bookshelf/")) {
            throw safeError("请先在 https://fanqienovel.com/bookshelf 登录并打开书架页面");
        }
        var entries = performance.getEntriesByType("resource");
        var shelfPath = "/reading/bookapi/bookshelf/info/";
        var shelfUrl = discoverUrl(entries, shelfPath);
        if (!shelfUrl) throw safeError("没有找到官方书架请求，请刷新页面、等待书架显示后再运行");

        var shelfPayload = await readJson(shelfUrl, shelfPath,
            { credentials: "include" }, "读取官方书架");
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
        if (!ids.length) throw safeError("官方书架中没有可导出的小说");
        if (ids.length > MAX_BOOKS) throw safeError("单次最多导出 500 本书");

        var detailPath = "/api/book/simple/info";
        var detailPayload = await readJson(detailPath, detailPath, {
            method: "POST",
            credentials: "include",
            headers: { "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({ book_ids: ids })
        }, "读取书籍信息");
        var progressPath = "/api/reader/book/progress";
        var progressUrl = discoverUrl(entries, progressPath);
        var progressPayload = progressUrl
            ? await readJson(progressUrl, progressPath,
                { credentials: "include" }, "读取阅读进度")
            : { code: 0, data: [] };
        var output = buildExport(shelfPayload, detailPayload, progressPayload);
        var text = JSON.stringify(output, null, 2);
        if (jsonSize(text) > MAX_BYTES) {
            output.books.forEach(function (book) { delete book.cover_url; });
            text = JSON.stringify(output, null, 2);
        }
        if (jsonSize(text) > MAX_BYTES) throw safeError("生成文件超过 256 KB，请减少书架数量后重试");

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
        officialUrl: officialUrl,
        publicFailureMessage: publicFailureMessage,
        readJson: readJson,
        run: run
    };
}));
