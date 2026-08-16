#!/usr/bin/env node
"use strict";

const fs = require("fs");
const MAX_FILE_BYTES = 1024 * 1024;

const EXACT_KEYS = {
    root: ["format", "version", "tested_at", "environment", "book", "chapter", "observation"],
    environment: ["kindle_model", "firmware", "koreader", "plugin_commit"],
    book: ["id", "chapter_count", "serialization", "category"],
    chapter: ["position", "id"],
    observation: [
        "response", "result", "visible_characters", "claimed_characters",
        "known_pua", "unknown_pua", "cache_saved", "garbled",
        "actionable_error", "structure_sha256",
    ],
};

function fail(message) {
    throw new Error(message);
}

function object(value, label) {
    if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} 必须是对象`);
}

function exactKeys(value, allowed, label) {
    object(value, label);
    const keys = Object.keys(value).sort();
    const expected = [...allowed].sort();
    if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) {
        fail(`${label} 字段不符合固定白名单`);
    }
}

function string(value, label, pattern) {
    if (typeof value !== "string" || !pattern.test(value)) fail(`${label} 格式无效`);
}

function integer(value, label, maximum = 10000000) {
    if (!Number.isSafeInteger(value) || value < 0 || value > maximum) fail(`${label} 必须是有效非负整数`);
}

function oneOf(value, label, values) {
    if (!values.includes(value)) fail(`${label} 不在允许范围内`);
}

function boolean(value, label) {
    if (typeof value !== "boolean") fail(`${label} 必须是布尔值`);
}

function validateRecord(record) {
    exactKeys(record, EXACT_KEYS.root, "记录");
    if (record.format !== "fanqielite-compatibility-record" || record.version !== 1) {
        fail("记录格式或版本不受支持");
    }
    string(record.tested_at, "tested_at", /^\d{4}-\d{2}-\d{2}$/);
    const testedAt = new Date(`${record.tested_at}T00:00:00Z`);
    if (Number.isNaN(testedAt.getTime()) || testedAt.toISOString().slice(0, 10) !== record.tested_at) {
        fail("tested_at 不是有效日期");
    }

    exactKeys(record.environment, EXACT_KEYS.environment, "environment");
    string(record.environment.kindle_model, "kindle_model", /^[A-Za-z0-9 ._+-]{1,40}$/);
    string(record.environment.firmware, "firmware", /^[A-Za-z0-9._+-]{1,40}$/);
    string(record.environment.koreader, "koreader", /^[A-Za-z0-9._+-]{1,40}$/);
    string(record.environment.plugin_commit, "plugin_commit", /^[0-9a-f]{7,40}$/);

    exactKeys(record.book, EXACT_KEYS.book, "book");
    string(record.book.id, "book.id", /^\d{10,30}$/);
    integer(record.book.chapter_count, "book.chapter_count");
    oneOf(record.book.serialization, "book.serialization", ["completed", "ongoing", "unknown"]);
    oneOf(record.book.category, "book.category", ["male", "female", "published", "other", "unknown"]);

    exactKeys(record.chapter, EXACT_KEYS.chapter, "chapter");
    oneOf(record.chapter.position, "chapter.position", ["first", "middle", "latest"]);
    string(record.chapter.id, "chapter.id", /^\d{10,30}$/);

    exactKeys(record.observation, EXACT_KEYS.observation, "observation");
    oneOf(record.observation.response, "observation.response", [
        "public_full", "short_preview", "login_wall", "locked",
        "rate_limited", "malformed", "other",
    ]);
    oneOf(record.observation.result, "observation.result", [
        "success", "safe_reject", "false_accept", "parse_failure",
    ]);
    integer(record.observation.visible_characters, "observation.visible_characters");
    integer(record.observation.claimed_characters, "observation.claimed_characters");
    integer(record.observation.known_pua, "observation.known_pua");
    integer(record.observation.unknown_pua, "observation.unknown_pua");
    boolean(record.observation.cache_saved, "observation.cache_saved");
    boolean(record.observation.garbled, "observation.garbled");
    boolean(record.observation.actionable_error, "observation.actionable_error");
    string(record.observation.structure_sha256, "observation.structure_sha256", /^[0-9a-f]{64}$/);

    return record;
}

function parseJsonLines(text) {
    const records = [];
    text.split(/\r?\n/).forEach((line, index) => {
        if (!line.trim()) return;
        let record;
        try {
            record = JSON.parse(line);
        } catch (_) {
            fail(`第 ${index + 1} 行不是有效 JSON`);
        }
        try {
            records.push(validateRecord(record));
        } catch (error) {
            fail(`第 ${index + 1} 行：${error.message}`);
        }
    });
    if (records.length === 0) fail("证据文件为空");
    return records;
}

function summarize(records) {
    const books = new Set();
    const scenarios = new Set();
    let publicTotal = 0;
    let publicCorrect = 0;
    let protectedTotal = 0;
    let protectedCorrect = 0;

    for (const record of records) {
        validateRecord(record);
        books.add(record.book.id);
        const scenario = `${record.book.id}:${record.chapter.position}:${record.chapter.id}`;
        if (scenarios.has(scenario)) fail("存在重复的书籍章节场景");
        scenarios.add(scenario);

        if (record.observation.response === "public_full") {
            publicTotal += 1;
            if (record.observation.result === "success" && !record.observation.garbled) publicCorrect += 1;
        } else if (["short_preview", "login_wall", "locked", "malformed"].includes(record.observation.response)) {
            protectedTotal += 1;
            if (record.observation.result === "safe_reject" && !record.observation.cache_saved) protectedCorrect += 1;
        }
    }

    return { records: records.length, books: books.size, publicTotal, publicCorrect, protectedTotal, protectedCorrect };
}

function percentage(correct, total) {
    return total === 0 ? "n/a" : `${(correct * 100 / total).toFixed(1)}%`;
}

function main(argv) {
    if (argv.length !== 1) fail("用法：node tools/compatibility-evidence.js <records.jsonl>");
    if (fs.statSync(argv[0]).size > MAX_FILE_BYTES) fail("证据文件超过 1 MB 限制");
    const records = parseJsonLines(fs.readFileSync(argv[0], "utf8"));
    const summary = summarize(records);
    process.stdout.write([
        `records=${summary.records}`,
        `books=${summary.books}`,
        `public_correct=${summary.publicCorrect}/${summary.publicTotal} (${percentage(summary.publicCorrect, summary.publicTotal)})`,
        `protected_correct=${summary.protectedCorrect}/${summary.protectedTotal} (${percentage(summary.protectedCorrect, summary.protectedTotal)})`,
    ].join("\n") + "\n");
}

if (require.main === module) {
    try {
        main(process.argv.slice(2));
    } catch (error) {
        process.stderr.write(`compatibility evidence error: ${error.message}\n`);
        process.exitCode = 1;
    }
}

module.exports = { parseJsonLines, summarize, validateRecord };
