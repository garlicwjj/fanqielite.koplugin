#!/usr/bin/env node
"use strict";

const fs = require("fs");
const MAX_FILE_BYTES = 1024 * 1024;
const REQUIRED_POSITIONS = ["first", "middle", "latest"];
const BAND_QUOTAS = [
    { key: "under_50", label: "少于 50 章", minimum: 5, matches: (count) => count < 50 },
    { key: "from_50_to_200", label: "50–200 章", minimum: 5, matches: (count) => count >= 50 && count <= 200 },
    { key: "from_201_to_500", label: "201–500 章", minimum: 8, matches: (count) => count >= 201 && count <= 500 },
    { key: "from_501_to_1000", label: "501–1000 章", minimum: 7, matches: (count) => count >= 501 && count <= 1000 },
    { key: "over_1000", label: "超过 1000 章", minimum: 5, matches: (count) => count > 1000 },
];
const REQUIRED_SAFETY_CASES = [
    { key: "short_preview", label: "短预览" },
    { key: "login_wall", label: "登录墙" },
    { key: "locked", label: "锁定章节" },
    { key: "malformed", label: "畸形响应" },
    { key: "id_mismatch", label: "章节 ID 不一致" },
    { key: "unknown_pua", label: "未知 PUA" },
];

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
    if (record.book.chapter_count < 1) fail("book.chapter_count 必须大于 0");
    oneOf(record.book.serialization, "book.serialization", ["completed", "ongoing", "unknown"]);
    oneOf(record.book.category, "book.category", ["male", "female", "published", "other", "unknown"]);

    exactKeys(record.chapter, EXACT_KEYS.chapter, "chapter");
    oneOf(record.chapter.position, "chapter.position", ["first", "middle", "latest"]);
    string(record.chapter.id, "chapter.id", /^\d{10,30}$/);

    exactKeys(record.observation, EXACT_KEYS.observation, "observation");
    oneOf(record.observation.response, "observation.response", [
        "public_full", "short_preview", "login_wall", "locked",
        "rate_limited", "malformed", "id_mismatch", "other",
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

function publicRecordCorrect(observation) {
    return observation.result === "success"
        && observation.cache_saved
        && !observation.garbled
        && observation.unknown_pua === 0
        && observation.visible_characters >= 500
        && (observation.claimed_characters === 0
            || observation.visible_characters >= observation.claimed_characters * 0.45);
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
            if (publicRecordCorrect(record.observation)) publicCorrect += 1;
        } else {
            protectedTotal += 1;
            if (record.observation.result === "safe_reject"
                    && !record.observation.cache_saved
                    && !record.observation.garbled
                    && record.observation.actionable_error) {
                protectedCorrect += 1;
            }
        }
    }

    return { records: records.length, books: books.size, publicTotal, publicCorrect, protectedTotal, protectedCorrect };
}

function evaluateMatrix(records) {
    const summary = summarize(records);
    const errors = [];
    const books = new Map();
    const pluginCommits = new Set();
    const bands = Object.fromEntries(BAND_QUOTAS.map((band) => [band.key, 0]));
    const serialization = { completed: 0, ongoing: 0, unknown: 0 };
    const category = { male: 0, female: 0, published: 0, other: 0, unknown: 0 };
    const safetyCoverage = Object.fromEntries(REQUIRED_SAFETY_CASES.map((item) => [item.key, 0]));
    let safeRejectTotal = 0;
    let safeRejectCorrect = 0;
    let hasRightsRestrictedScenario = false;

    for (const record of records) {
        pluginCommits.add(record.environment.plugin_commit);
        let book = books.get(record.book.id);
        if (!book) {
            book = {
                chapter_count: record.book.chapter_count,
                serialization: record.book.serialization,
                category: record.book.category,
                positions: new Map(),
                chapterIds: new Set(),
                inconsistent: false,
            };
            books.set(record.book.id, book);
        } else if (book.chapter_count !== record.book.chapter_count
                || book.serialization !== record.book.serialization
                || book.category !== record.book.category) {
            book.inconsistent = true;
        }

        if (book.positions.has(record.chapter.position)) {
            book.positions.set(record.chapter.position, null);
        } else {
            book.positions.set(record.chapter.position, record.chapter.id);
        }
        book.chapterIds.add(record.chapter.id);

        const requiresSafeReject = record.observation.response !== "public_full"
            || record.observation.unknown_pua > 0;
        if (requiresSafeReject) {
            safeRejectTotal += 1;
            if (record.observation.result === "safe_reject"
                    && !record.observation.cache_saved
                    && !record.observation.garbled
                    && record.observation.actionable_error) {
                safeRejectCorrect += 1;
            }
        }
        if (["login_wall", "locked"].includes(record.observation.response)) {
            hasRightsRestrictedScenario = true;
        }
        if (Object.prototype.hasOwnProperty.call(safetyCoverage, record.observation.response)) {
            safetyCoverage[record.observation.response] += 1;
        }
        if (record.observation.unknown_pua > 0) safetyCoverage.unknown_pua += 1;
    }

    for (const [bookId, book] of books) {
        if (book.inconsistent) errors.push(`书籍 ${bookId} 的元数据不一致`);
        if (book.chapter_count < 3) errors.push(`书籍 ${bookId} 少于 3 章，无法覆盖前、中、末场景`);
        const hasEveryPosition = REQUIRED_POSITIONS.every((position) => book.positions.get(position));
        if (book.positions.size !== REQUIRED_POSITIONS.length || !hasEveryPosition
                || book.chapterIds.size !== REQUIRED_POSITIONS.length) {
            errors.push(`书籍 ${bookId} 必须各有一个互不重复的前、中、末章节场景`);
        }
        const band = BAND_QUOTAS.find((candidate) => candidate.matches(book.chapter_count));
        if (band) bands[band.key] += 1;
        serialization[book.serialization] += 1;
        category[book.category] += 1;
    }

    if (books.size < 30) errors.push(`至少需要 30 本书，当前 ${books.size} 本`);
    if (summary.records < 90) errors.push(`至少需要 90 个章节场景，当前 ${summary.records} 个`);
    for (const band of BAND_QUOTAS) {
        if (bands[band.key] < band.minimum) {
            errors.push(`${band.label}至少 ${band.minimum} 本，当前 ${bands[band.key]} 本`);
        }
    }
    if (serialization.completed < 12) {
        errors.push(`至少 12 本已完结，当前 ${serialization.completed} 本`);
    }
    if (serialization.ongoing < 18) {
        errors.push(`至少 18 本连载中，当前 ${serialization.ongoing} 本`);
    }
    if (category.male < 1) errors.push("至少需要 1 本男频样本");
    if (category.female < 1) errors.push("至少需要 1 本女频样本");
    if (category.published < 1 && !hasRightsRestrictedScenario) {
        errors.push("至少需要 1 本出版样本或版权受限场景");
    }
    if (pluginCommits.size !== 1) errors.push("完整矩阵必须使用同一个插件候选提交");
    for (const safetyCase of REQUIRED_SAFETY_CASES) {
        if (safetyCoverage[safetyCase.key] < 1) {
            errors.push(`至少需要 1 个${safetyCase.label}安全场景`);
        }
    }
    if (summary.publicTotal === 0 || summary.publicCorrect / summary.publicTotal < 0.95) {
        errors.push(`公开正文正确解析率必须达到 95%，当前 ${percentage(summary.publicCorrect, summary.publicTotal)}`);
    }
    if (safeRejectCorrect !== safeRejectTotal) {
        errors.push(`非公开或未知 PUA 场景必须全部安全拒绝，当前 ${safeRejectCorrect}/${safeRejectTotal}`);
    }

    return {
        complete: errors.length === 0,
        errors,
        books: books.size,
        scenarios: summary.records,
        bands,
        serialization,
        category,
        safetyCoverage,
        publicTotal: summary.publicTotal,
        publicCorrect: summary.publicCorrect,
        safeRejectTotal,
        safeRejectCorrect,
    };
}

function percentage(correct, total) {
    return total === 0 ? "n/a" : `${(correct * 100 / total).toFixed(1)}%`;
}

function main(argv) {
    const requireComplete = argv[0] === "--require-complete";
    const path = requireComplete ? argv[1] : argv[0];
    if (!path || argv.length !== (requireComplete ? 2 : 1)) {
        fail("用法：node tools/compatibility-evidence.js [--require-complete] <records.jsonl>");
    }
    if (fs.statSync(path).size > MAX_FILE_BYTES) fail("证据文件超过 1 MB 限制");
    const records = parseJsonLines(fs.readFileSync(path, "utf8"));
    const summary = summarize(records);
    const matrix = evaluateMatrix(records);
    process.stdout.write([
        `records=${summary.records}`,
        `books=${summary.books}`,
        `public_correct=${summary.publicCorrect}/${summary.publicTotal} (${percentage(summary.publicCorrect, summary.publicTotal)})`,
        `non_public_safe_reject=${summary.protectedCorrect}/${summary.protectedTotal} (${percentage(summary.protectedCorrect, summary.protectedTotal)})`,
        `safe_reject_correct=${matrix.safeRejectCorrect}/${matrix.safeRejectTotal} (${percentage(matrix.safeRejectCorrect, matrix.safeRejectTotal)})`,
        `bands=${BAND_QUOTAS.map((band) => `${band.key}:${matrix.bands[band.key]}`).join(",")}`,
        `serialization=completed:${matrix.serialization.completed},ongoing:${matrix.serialization.ongoing},unknown:${matrix.serialization.unknown}`,
        `category=male:${matrix.category.male},female:${matrix.category.female},published:${matrix.category.published},other:${matrix.category.other},unknown:${matrix.category.unknown}`,
        `safety_coverage=${REQUIRED_SAFETY_CASES.map((item) => `${item.key}:${matrix.safetyCoverage[item.key]}`).join(",")}`,
        `matrix_complete=${matrix.complete ? "yes" : "no"}`,
        `matrix_errors=${matrix.errors.length}`,
    ].join("\n") + "\n");
    if (requireComplete && !matrix.complete) {
        fail(`完整矩阵门禁未通过：\n- ${matrix.errors.join("\n- ")}`);
    }
}

if (require.main === module) {
    try {
        main(process.argv.slice(2));
    } catch (error) {
        process.stderr.write(`compatibility evidence error: ${error.message}\n`);
        process.exitCode = 1;
    }
}

module.exports = { evaluateMatrix, parseJsonLines, summarize, validateRecord };
