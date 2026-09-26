#!/usr/bin/env node
"use strict";

const MAX_HTML_BYTES = 1024 * 1024;
const ID_PATTERN = /^\d{10,64}$/;
const INITIAL_STATE_MARKER = "window.__INITIAL_STATE__=";

function fail(message) { throw new Error(message); }

function validDate(value) {
    if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
    const date = new Date(`${value}T00:00:00Z`);
    return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function sourceBookId(sourceUrl) {
    let source;
    try { source = new URL(sourceUrl); }
    catch (_) { fail("官网书籍页地址无效"); }
    const match = source.pathname.match(/^\/page\/(\d{10,64})$/);
    if (source.origin !== "https://fanqienovel.com" || !match
            || source.search || source.hash || source.username || source.password) {
        fail("必须提供无查询参数的番茄官网 /page/<书籍ID> 地址");
    }
    return match[1];
}

function initialStateJson(html) {
    if (typeof html !== "string") fail("官网页面输入必须是文本");
    if (Buffer.byteLength(html, "utf8") > MAX_HTML_BYTES) fail("官网页面输入超过 1 MB");
    const markerAt = html.indexOf(INITIAL_STATE_MARKER);
    if (markerAt < 0) fail("官网页面没有可识别的初始状态");
    const start = html.indexOf("{", markerAt + INITIAL_STATE_MARKER.length);
    if (start < 0) fail("官网页面初始状态不完整");

    let depth = 0;
    let quoted = false;
    let escaped = false;
    for (let index = start; index < html.length; index += 1) {
        const character = html[index];
        if (quoted) {
            if (escaped) escaped = false;
            else if (character === "\\") escaped = true;
            else if (character === "\"") quoted = false;
            continue;
        }
        if (character === "\"") quoted = true;
        else if (character === "{") depth += 1;
        else if (character === "}" && --depth === 0) return html.slice(start, index + 1);
    }
    fail("官网页面初始状态不完整");
}

function pageState(html) {
    let state;
    try { state = JSON.parse(initialStateJson(html)); }
    catch (error) {
        if (error && error.message && error.message.startsWith("官网页面")) throw error;
        fail("官网页面初始状态不是有效 JSON");
    }
    if (!state || typeof state !== "object" || Array.isArray(state)
            || !state.page || typeof state.page !== "object" || Array.isArray(state.page)) {
        fail("官网页面缺少书籍状态");
    }
    return state.page;
}

function serializationFromPage(page) {
    if (page.creationStatus === 0) return "completed";
    if (page.creationStatus === 1) return "ongoing";
    fail("官网页面返回未知连载状态");
}

function categoryFromPage(page) {
    if (typeof page.categoryV2 !== "string" || Buffer.byteLength(page.categoryV2, "utf8") > 128 * 1024) {
        fail("官网页面缺少可识别的分类");
    }
    let categories;
    try { categories = JSON.parse(page.categoryV2); }
    catch (_) { fail("官网页面分类不是有效 JSON"); }
    if (!Array.isArray(categories) || categories.length > 1000) {
        fail("官网页面分类结构无效");
    }
    const primary = categories.filter((item) => item && typeof item === "object"
        && !Array.isArray(item) && item.MainCategory === true);
    if (primary.length !== 1) fail("官网页面主分类不唯一");
    if (primary[0].Name === "精品小说") return "published";
    if (primary[0].Gender === 1) return "male";
    if (primary[0].Gender === 0) return "female";
    fail("官网页面主分类无法映射到兼容矩阵");
}

function buildCandidate(html, options) {
    if (!options || typeof options !== "object" || Array.isArray(options)) fail("缺少候选参数");
    if (!validDate(options.observedAt)) fail("观测日期必须是 YYYY-MM-DD 有效日期");
    if (!Number.isSafeInteger(options.chapterCount)
            || options.chapterCount < 3 || options.chapterCount > 10000) {
        fail("生产目录解析章数必须是 3 到 10000 的整数");
    }
    const expectedId = sourceBookId(options.sourceUrl);
    const page = pageState(html);
    if (typeof page.bookId !== "string" || !ID_PATTERN.test(page.bookId)
            || page.bookId !== expectedId) {
        fail("官网页面书籍 ID 与地址不一致");
    }
    if (!Number.isSafeInteger(page.chapterTotal) || page.chapterTotal !== options.chapterCount) {
        fail("官网页面章数与生产目录解析结果不一致");
    }
    return {
        format: "fanqielite-compatibility-candidate",
        version: 1,
        observed_at: options.observedAt,
        source_url: options.sourceUrl,
        book: {
            id: expectedId,
            chapter_count: options.chapterCount,
            serialization: serializationFromPage(page),
            category: categoryFromPage(page),
        },
    };
}

function parseArguments(argv) {
    if (argv.length !== 3) {
        fail("用法：node tools/compatibility-page-candidate.js <YYYY-MM-DD> <生产目录章数> <官网书籍页> < page.html");
    }
    if (!/^\d+$/.test(argv[1])) fail("生产目录解析章数必须是整数");
    return { observedAt: argv[0], chapterCount: Number(argv[1]), sourceUrl: argv[2] };
}

function main(argv, input) {
    const candidate = buildCandidate(input, parseArguments(argv));
    process.stdout.write(`${JSON.stringify(candidate)}\n`);
}

if (require.main === module) {
    const chunks = [];
    let bytes = 0;
    process.stdin.on("data", (chunk) => {
        bytes += chunk.length;
        if (bytes > MAX_HTML_BYTES) {
            process.stderr.write("compatibility page candidate error: 官网页面输入超过 1 MB\n");
            process.exit(1);
        }
        chunks.push(chunk);
    });
    process.stdin.on("end", () => {
        try { main(process.argv.slice(2), Buffer.concat(chunks).toString("utf8")); }
        catch (error) {
            process.stderr.write(`compatibility page candidate error: ${error.message}\n`);
            process.exitCode = 1;
        }
    });
    process.stdin.resume();
}

module.exports = {
    buildCandidate,
    categoryFromPage,
    initialStateJson,
    pageState,
    parseArguments,
    serializationFromPage,
    sourceBookId,
};
