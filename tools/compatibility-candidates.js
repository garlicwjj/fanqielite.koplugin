#!/usr/bin/env node
"use strict";

const fs = require("fs");
const { BAND_QUOTAS } = require("./compatibility-evidence");

const MAX_FILE_BYTES = 128 * 1024;
const ID_PATTERN = /^\d{10,64}$/;
const EXACT_KEYS = {
    root: ["format", "version", "observed_at", "source_url", "book"],
    book: ["id", "chapter_count", "serialization", "category"],
};

function fail(message) { throw new Error(message); }

function exactKeys(value, allowed, label) {
    if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} 必须是对象`);
    const keys = Object.keys(value).sort();
    const expected = [...allowed].sort();
    if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) {
        fail(`${label} 字段不符合固定白名单`);
    }
}

function validateCandidate(candidate) {
    exactKeys(candidate, EXACT_KEYS.root, "候选记录");
    if (candidate.format !== "fanqielite-compatibility-candidate" || candidate.version !== 1) {
        fail("候选记录格式或版本不受支持");
    }
    if (typeof candidate.observed_at !== "string"
            || !/^\d{4}-\d{2}-\d{2}$/.test(candidate.observed_at)) {
        fail("observed_at 格式无效");
    }
    const date = new Date(`${candidate.observed_at}T00:00:00Z`);
    if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== candidate.observed_at) {
        fail("observed_at 不是有效日期");
    }

    exactKeys(candidate.book, EXACT_KEYS.book, "book");
    if (typeof candidate.book.id !== "string" || !ID_PATTERN.test(candidate.book.id)) {
        fail("book.id 格式无效");
    }
    if (!Number.isSafeInteger(candidate.book.chapter_count)
            || candidate.book.chapter_count < 3 || candidate.book.chapter_count > 10000) {
        fail("book.chapter_count 必须是 3 到 10000 的整数");
    }
    if (!["completed", "ongoing"].includes(candidate.book.serialization)) {
        fail("book.serialization 必须明确为 completed 或 ongoing");
    }
    if (!["male", "female", "published", "other"].includes(candidate.book.category)) {
        fail("book.category 不在允许范围内");
    }

    if (typeof candidate.source_url !== "string") fail("source_url 不是有效官网书籍页");
    let source;
    try { source = new URL(candidate.source_url); }
    catch (_) { fail("source_url 不是有效官网书籍页"); }
    if (source.origin !== "https://fanqienovel.com"
            || source.pathname !== `/page/${candidate.book.id}`
            || source.search || source.hash || source.username || source.password) {
        fail("source_url 必须是与 book.id 一致的番茄官网书籍页");
    }
    return candidate;
}

function parseCandidates(text) {
    const records = [];
    text.split(/\r?\n/).forEach((line, index) => {
        if (!line.trim()) return;
        let candidate;
        try { candidate = JSON.parse(line); }
        catch (_) { fail(`第 ${index + 1} 行不是有效 JSON`); }
        try { records.push(validateCandidate(candidate)); }
        catch (error) { fail(`第 ${index + 1} 行：${error.message}`); }
    });
    return records;
}

function evaluateCandidates(records) {
    const seen = new Set();
    const bands = Object.fromEntries(BAND_QUOTAS.map((band) => [band.key, 0]));
    const serialization = { completed: 0, ongoing: 0 };
    const category = { male: 0, female: 0, published: 0, other: 0 };
    for (const candidate of records) {
        validateCandidate(candidate);
        if (seen.has(candidate.book.id)) fail("候选清单包含重复书籍 ID");
        seen.add(candidate.book.id);
        const band = BAND_QUOTAS.find((item) => item.matches(candidate.book.chapter_count));
        if (!band) fail("候选书目录长度不在矩阵范围内");
        bands[band.key] += 1;
        serialization[candidate.book.serialization] += 1;
        category[candidate.book.category] += 1;
    }

    const errors = [];
    if (seen.size !== 30) errors.push(`候选清单必须恰好 30 本，当前 ${seen.size} 本`);
    for (const band of BAND_QUOTAS) {
        if (bands[band.key] < band.minimum) {
            errors.push(`${band.label}至少 ${band.minimum} 本，当前 ${bands[band.key]} 本`);
        }
    }
    if (serialization.completed < 12) errors.push(`至少 12 本已完结，当前 ${serialization.completed} 本`);
    if (serialization.ongoing < 18) errors.push(`至少 18 本连载中，当前 ${serialization.ongoing} 本`);
    if (category.male < 1) errors.push("至少需要 1 本男频候选");
    if (category.female < 1) errors.push("至少需要 1 本女频候选");
    if (category.published < 1) errors.push("至少需要 1 本出版候选");
    return { complete: errors.length === 0, errors, books: seen.size, bands, serialization, category };
}

function main(argv) {
    const requireComplete = argv[0] === "--require-complete";
    const file = requireComplete ? argv[1] : argv[0];
    if (!file || argv.length !== (requireComplete ? 2 : 1)) {
        fail("用法：node tools/compatibility-candidates.js [--require-complete] <candidates.jsonl>");
    }
    let text;
    try {
        const stat = fs.statSync(file);
        if (!stat.isFile()) fail("候选清单不是普通文件");
        if (stat.size > MAX_FILE_BYTES) fail("候选清单超过 128 KB 限制");
        text = fs.readFileSync(file, "utf8");
    } catch (error) {
        if (error && typeof error.message === "string" && error.message.startsWith("候选清单")) throw error;
        fail("无法读取候选清单");
    }
    const result = evaluateCandidates(parseCandidates(text));
    process.stdout.write([
        `books=${result.books}`,
        `bands=${BAND_QUOTAS.map((band) => `${band.key}:${result.bands[band.key]}`).join(",")}`,
        `serialization=completed:${result.serialization.completed},ongoing:${result.serialization.ongoing}`,
        `category=male:${result.category.male},female:${result.category.female},published:${result.category.published},other:${result.category.other}`,
        `candidate_set_complete=${result.complete ? "yes" : "no"}`,
        `candidate_set_errors=${result.errors.length}`,
    ].join("\n") + "\n");
    if (requireComplete && !result.complete) {
        fail(`候选清单门禁未通过：\n- ${result.errors.join("\n- ")}`);
    }
}

if (require.main === module) {
    try { main(process.argv.slice(2)); }
    catch (error) {
        process.stderr.write(`compatibility candidates error: ${error.message}\n`);
        process.exitCode = 1;
    }
}

module.exports = { evaluateCandidates, parseCandidates, validateCandidate };
