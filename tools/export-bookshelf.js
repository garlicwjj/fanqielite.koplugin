(function (root, factory) {
    "use strict";
    var api = factory();
    if (typeof module === "object" && module.exports) {
        module.exports = api;
    } else {
        var options = root.FANQIELITE_AUTHOR_DIAGNOSTIC === true ? { diagnostic: true } : undefined;
        api.run(options).catch(function (error) {
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
        if (value.length > 2048 || /[\x00-\x20\x7f]/.test(value)
                || /%(?![0-9a-f]{2})/i.test(value)
                || /%(?:0[0-9a-f]|1[0-9a-f]|7f)/i.test(value)) return "";
        var parsed;
        try { parsed = new URL(value); }
        catch (_) { return ""; }
        if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.hash) return "";
        if (parsed.hostname.indexOf("[") === 0 || parsed.hostname.length > 253
                || parsed.hostname.split(".").some(function (label) {
                    return !label || label.length > 63
                        || label.indexOf("-") === 0 || label.slice(-1) === "-";
                })) return "";
        if (parsed.port && (Number(parsed.port) < 1 || Number(parsed.port) > 65535)) return "";
        var unsafeQuery = false;
        parsed.searchParams.forEach(function (_, key) {
            var normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");
            if (normalized === "auth"
                    || /authorization|cookie|csrf|mobile|password|phone|session|telephone|token/.test(normalized)) {
                unsafeQuery = true;
            }
        });
        if (unsafeQuery) return "";
        return parsed.href;
    }

    function responseData(payload, label) {
        if (!payload || typeof payload !== "object" || payload.code !== 0) {
            throw safeError(label + "失败，已停止导出");
        }
        return payload.data || {};
    }

    function shelfNovelIds(shelfPayload) {
        var shelfData = responseData(shelfPayload, "读取官方书架");
        if (!Array.isArray(shelfData.book_shelf_info)) {
            throw safeError("官方书架返回未知结构，已停止导出");
        }
        var shelf = shelfData.book_shelf_info;
        if (shelf.length > MAX_BOOKS) throw safeError("单次最多导出 500 本书");
        var ids = [];
        var seen = {};
        shelf.forEach(function (item) {
            if (!item || typeof item !== "object" || Array.isArray(item)) {
                throw safeError("官方书架包含无效条目，已停止导出");
            }
            var bookType = item.book_type;
            if (bookType !== undefined && bookType !== 0 && bookType !== "0") {
                var knownOtherType = (typeof bookType === "number" && Number.isInteger(bookType))
                    || (typeof bookType === "string" && /^\d{1,3}$/.test(bookType));
                if (!knownOtherType) throw safeError("官方书架包含未知书籍类型，已停止导出");
                return;
            }
            var id = normalizeId(item.book_id);
            if (!id) throw safeError("官方书架包含无效书籍 ID，已停止导出");
            if (!seen[id]) {
                seen[id] = true;
                ids.push(id);
            }
        });
        if (!ids.length) {
            throw safeError("官方书架中没有可导出的小说，请确认已经登录并打开书架页面");
        }
        return ids;
    }

    function requiredDetails(detailPayload, ids) {
        var detailData = responseData(detailPayload, "读取书籍信息");
        var details = Array.isArray(detailData.bookList) ? detailData.bookList
            : (Array.isArray(detailData.book_list) ? detailData.book_list : null);
        if (!details) throw safeError("书籍信息返回未知结构，已停止导出");
        if (details.length > MAX_BOOKS) throw safeError("书籍信息数量异常，已停止导出");
        var requested = {};
        ids.forEach(function (id) { requested[id] = true; });
        var detailById = {};
        details.forEach(function (item) {
            if (!item || typeof item !== "object" || Array.isArray(item)) {
                throw safeError("书籍信息包含无效条目，已停止导出");
            }
            var id = normalizeId(item.book_id);
            if (!id || !requested[id] || detailById[id]) {
                throw safeError("书籍信息与官方书架不一致，已停止导出");
            }
            detailById[id] = item;
        });
        ids.forEach(function (id) {
            if (!detailById[id]) throw safeError("书籍信息不完整，已停止导出");
            if (!cleanText(detailById[id].book_name, 100)) {
                throw safeError("书籍信息中的书名无效，已停止导出");
            }
        });
        return detailById;
    }

    function validatedProgress(progressPayload, ids) {
        if (progressPayload === undefined) return {};
        var progress = responseData(progressPayload, "读取阅读进度");
        if (!Array.isArray(progress)) {
            throw safeError("读取阅读进度返回未知结构，已停止导出");
        }
        if (progress.length > MAX_BOOKS) {
            throw safeError("阅读进度数量异常，已停止导出");
        }
        var requested = {};
        ids.forEach(function (id) { requested[id] = true; });
        var progressById = {};
        progress.forEach(function (item) {
            if (!item || typeof item !== "object" || Array.isArray(item)) {
                throw safeError("阅读进度包含无效条目，已停止导出");
            }
            var id = normalizeId(item.book_id);
            if (!id) throw safeError("阅读进度包含无效书籍 ID，已停止导出");
            if (!requested[id]) return;
            if (progressById[id]) {
                throw safeError("阅读进度包含重复书籍 ID，已停止导出");
            }
            var chapterId = normalizeId(item.item_id);
            if (!chapterId) throw safeError("阅读进度包含无效章节 ID，已停止导出");
            var titleFields = ["origin_chapter_title", "title", "item_title", "chapter_title"];
            var chapterTitle = "";
            titleFields.some(function (field) {
                chapterTitle = cleanText(item[field], 100);
                return chapterTitle !== "";
            });
            progressById[id] = { chapter_id: chapterId, chapter_title: chapterTitle };
        });
        return progressById;
    }

    function buildExport(shelfPayload, detailPayload, progressPayload, exportedAt) {
        var ids = shelfNovelIds(shelfPayload);
        var detailById = requiredDetails(detailPayload, ids);
        var progressById = validatedProgress(progressPayload, ids);

        var books = [];
        ids.forEach(function (id) {
            var detail = detailById[id];
            var current = progressById[id] || {};
            var book = {
                id: id,
                title: cleanText(detail.book_name, 100)
            };
            var author = cleanText(detail.author || detail.author_name, 50);
            var cover = normalizeCover(detail.thumb_url || detail.thumb_uri);
            var chapterId = current.chapter_id;
            var chapterTitle = current.chapter_title;
            if (author) book.author = author;
            if (cover) book.cover_url = cover;
            if (chapterId) book.current_chapter_id = chapterId;
            if (chapterId && chapterTitle) book.current_chapter_title = chapterTitle;
            books.push(book);
        });
        return {
            format: "fanqielite-bookshelf",
            version: 1,
            exported_at: exportedAt || new Date().toISOString(),
            books: books
        };
    }

    function exportSummary(output, progressRequestFound) {
        var missingAuthors = output.books.filter(function (book) { return !book.author; }).length;
        var missingChapters = output.books.filter(function (book) {
            return !book.current_chapter_id;
        }).length;
        var message = "已导出 " + output.books.length + " 本书。";
        if (missingAuthors) message += "\n其中 " + missingAuthors + " 本未获得作者。";
        if (!progressRequestFound) {
            message += "\n页面未发现官方阅读进度请求，本次没有获取最近阅读章节。";
        } else if (missingChapters) {
            message += "\n其中 " + missingChapters + " 本未获得最近阅读章节，可能尚未阅读或官网未提供。";
        }
        return message + "\n章节内位置不会导出；这不是完整的阅读进度备份。"
            + "\n\n文件不包含 Cookie、Token、手机号或登录凭证。请把 "
            + FILENAME + " 复制到 Kindle，再从 Fanqie Lite 中导入。";
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

    function discoverShelfUrl(entries) {
        for (var index = entries.length - 1; index >= 0; index -= 1) {
            var name = entries[index] && entries[index].name;
            if (typeof name !== "string") continue;
            var parsed;
            try { parsed = new URL(name); }
            catch (_) { continue; }
            if (!/^\/reading\/bookapi\/bookshelf\/info\/(?:v(?:[0-9]{1,3}|:version)\/)?$/.test(parsed.pathname)) continue;
            var url = officialUrl(name, parsed.pathname);
            if (url) return url;
        }
        return "";
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
        var controller = new AbortController();
        var timedOut = false;
        var timer = setTimeout(function () {
            timedOut = true;
            controller.abort();
        }, 20000);
        var requestOptions = Object.assign({}, options || { credentials: "include" }, {
            redirect: "error",
            signal: controller.signal
        });
        try {
            var response;
            try { response = await (fetcher || fetch)(requestUrl, requestOptions); }
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
        } catch (error) {
            if (timedOut) throw safeError(label + "超时，已停止导出；请检查网络后重试");
            throw error;
        } finally {
            clearTimeout(timer);
            controller.abort();
        }
    }

    function authorDiagnostics(payload) {
        var data = responseData(payload, "读取书籍信息");
        var list = Array.isArray(data.bookList) ? data.bookList : data.book_list;
        if (!Array.isArray(list) || list.length > MAX_BOOKS) {
            throw safeError("详情列表结构无法诊断，已停止");
        }
        var fields = ["author", "author_name", "authorName", "authors", "author_list", "author_info"];
        return { count: list.length, author_fields: fields.map(function (field) {
            var types = {};
            list.forEach(function (item) {
                var value = item && Object.prototype.hasOwnProperty.call(item, field) ? item[field] : undefined;
                var type = value === undefined ? "missing" : value === null ? "null"
                    : Array.isArray(value) ? "array" : typeof value;
                types[type] = (types[type] || 0) + 1;
            });
            return { field: field, types: types };
        }) };
    }

    async function run(options) {
        if (location.origin !== OFFICIAL_ORIGIN
                || (location.pathname !== "/bookshelf" && location.pathname !== "/bookshelf/")) {
            throw safeError("请先在 https://fanqienovel.com/bookshelf 登录并打开书架页面");
        }
        var entries = performance.getEntriesByType("resource");
        var shelfUrl = discoverShelfUrl(entries);
        if (!shelfUrl) throw safeError("没有找到官方书架请求，请刷新页面、等待书架显示后再运行");
        var shelfPath = new URL(shelfUrl).pathname;

        var shelfPayload = await readJson(shelfUrl, shelfPath,
            { credentials: "include" }, "读取官方书架");
        var ids = shelfNovelIds(shelfPayload);

        var detailPath = "/api/book/simple/info";
        var detailPayload = await readJson(detailPath, detailPath, {
            method: "POST",
            credentials: "include",
            headers: { "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({ book_ids: ids })
        }, "读取书籍信息");
        requiredDetails(detailPayload, ids);
        if (options && options.diagnostic === true) {
            var report = authorDiagnostics(detailPayload);
            alert("Fanqie Lite 作者字段诊断（未导出文件）\n" + JSON.stringify(report));
            return report;
        }
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
        alert(exportSummary(output, !!progressUrl));
    }

    return {
        buildExport: buildExport,
        exportSummary: exportSummary,
        authorDiagnostics: authorDiagnostics,
        cleanText: cleanText,
        discoverUrl: discoverUrl,
        discoverShelfUrl: discoverShelfUrl,
        normalizeCover: normalizeCover,
        normalizeId: normalizeId,
        officialUrl: officialUrl,
        publicFailureMessage: publicFailureMessage,
        requiredDetails: requiredDetails,
        readJson: readJson,
        shelfNovelIds: shelfNovelIds,
        validatedProgress: validatedProgress,
        run: run
    };
}));
