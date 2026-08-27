"use strict";

const assert = require("assert");
const childProcess = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { evaluateMatrix, parseJsonLines, summarize, validateRecord } = require("../tools/compatibility-evidence");

function record(overrides = {}) {
    const value = {
        format: "fanqielite-compatibility-record",
        version: 1,
        tested_at: "2026-08-16",
        environment: {
            kindle_model: "PW3",
            firmware: "5.16.2.1.1",
            koreader: "2026.03",
            plugin_commit: "43864ae",
        },
        book: { id: "7633875868615461950", chapter_count: 88, serialization: "ongoing", category: "male" },
        chapter: { position: "first", id: "7633875868615461951" },
        observation: {
            response: "public_full",
            result: "success",
            visible_characters: 1800,
            claimed_characters: 1700,
            known_pua: 12,
            unknown_pua: 0,
            cache_saved: true,
            garbled: false,
            actionable_error: false,
            structure_sha256: "a".repeat(64),
        },
    };
    return Object.assign(value, overrides);
}

validateRecord(record());

assert.throws(() => validateRecord({ ...record(), cookie: "secret" }), /白名单/);
assert.throws(() => validateRecord({ ...record(), content: "novel text" }), /白名单/);
assert.throws(() => validateRecord({ ...record(), book: { ...record().book, title: "不应保存书名" } }), /白名单/);
assert.throws(() => validateRecord({ ...record(), observation: { ...record().observation, structure_sha256: "bad" } }), /格式无效/);
assert.throws(() => validateRecord({ ...record(), tested_at: "2026-02-31" }), /有效日期/);
assert.throws(() => validateRecord({ ...record(), book: { ...record().book, chapter_count: 0 } }), /大于 0/);

const locked = record();
locked.chapter = { position: "latest", id: "7633875868615461952" };
locked.observation = {
    ...locked.observation,
    response: "locked",
    result: "safe_reject",
    visible_characters: 0,
    claimed_characters: 0,
    cache_saved: false,
    actionable_error: true,
    structure_sha256: "b".repeat(64),
};

const parsed = parseJsonLines(`${JSON.stringify(record())}\n${JSON.stringify(locked)}\n`);
const summary = summarize(parsed);
assert.deepStrictEqual(summary, {
    records: 2,
    books: 1,
    publicTotal: 1,
    publicCorrect: 1,
    protectedTotal: 1,
    protectedCorrect: 1,
});

const uncachedPublic = record();
uncachedPublic.observation.cache_saved = false;
assert.strictEqual(summarize([uncachedPublic]).publicCorrect, 0,
    "uncached public chapter counted as correct");

const shortPublic = record();
shortPublic.observation.visible_characters = 499;
shortPublic.observation.claimed_characters = 0;
assert.strictEqual(summarize([shortPublic]).publicCorrect, 0,
    "short public preview counted as correct");

const incompletePublic = record();
incompletePublic.observation.visible_characters = 600;
incompletePublic.observation.claimed_characters = 2000;
assert.strictEqual(summarize([incompletePublic]).publicCorrect, 0,
    "incomplete claimed chapter counted as correct");

const unknownPuaPublic = record();
unknownPuaPublic.observation.unknown_pua = 1;
assert.strictEqual(summarize([unknownPuaPublic]).publicCorrect, 0,
    "unknown PUA public chapter counted as correct");

assert.throws(() => summarize([record(), record()]), /重复/);
assert.throws(() => parseJsonLines("{not json}\n"), /第 1 行/);

function completeMatrix() {
    const bands = [
        { books: 5, chapters: 30 },
        { books: 5, chapters: 100 },
        { books: 8, chapters: 300 },
        { books: 7, chapters: 700 },
        { books: 5, chapters: 1200 },
    ];
    const positions = ["first", "middle", "latest"];
    const records = [];
    let bookNumber = 0;
    for (const band of bands) {
        for (let offset = 0; offset < band.books; offset += 1) {
            bookNumber += 1;
            const bookId = String(8000000000 + bookNumber);
            const serialization = bookNumber <= 12 ? "completed" : "ongoing";
            const category = bookNumber === 1 ? "published" : (bookNumber % 2 ? "male" : "female");
            positions.forEach((position, positionIndex) => {
                const value = record();
                value.book = {
                    id: bookId,
                    chapter_count: band.chapters,
                    serialization,
                    category,
                };
                value.chapter = {
                    position,
                    id: String(9000000000 + bookNumber * 10 + positionIndex),
                };
                value.observation = {
                    ...value.observation,
                    structure_sha256: "0123456789abcdef"[bookNumber % 16].repeat(64),
                };
                records.push(value);
            });
        }
    }
    const reject = (index, response, unknownPua = 0) => {
        records[index].observation = {
            ...records[index].observation,
            response,
            result: "safe_reject",
            visible_characters: 0,
            claimed_characters: 0,
            known_pua: 0,
            unknown_pua: unknownPua,
            cache_saved: false,
            garbled: false,
            actionable_error: true,
        };
    };
    reject(0, "short_preview");
    reject(1, "login_wall");
    reject(2, "locked");
    reject(3, "malformed");
    reject(4, "id_mismatch");
    reject(5, "public_full", 1);
    return records;
}

const matrix = completeMatrix();
const matrixGate = evaluateMatrix(matrix);
assert.strictEqual(matrixGate.complete, true);
assert.deepStrictEqual(matrixGate.errors, []);
assert.strictEqual(matrixGate.books, 30);
assert.strictEqual(matrixGate.scenarios, 90);
assert.deepStrictEqual(matrixGate.bands, {
    under_50: 5,
    from_50_to_200: 5,
    from_201_to_500: 8,
    from_501_to_1000: 7,
    over_1000: 5,
});
assert.deepStrictEqual(matrixGate.serialization, { completed: 12, ongoing: 18, unknown: 0 });
assert.strictEqual(matrixGate.safeRejectCorrect, 6);
assert.strictEqual(matrixGate.safeRejectTotal, 6);

const incomplete = evaluateMatrix(matrix.slice(0, -1));
assert.strictEqual(incomplete.complete, false);
assert(incomplete.errors.some((error) => error.includes("90 个章节场景")));
assert(incomplete.errors.some((error) => error.includes("前、中、末")));

const wrongBand = completeMatrix();
wrongBand.slice(0, 3).forEach((value) => { value.book.chapter_count = 50; });
assert(evaluateMatrix(wrongBand).errors.some((error) => error.includes("少于 50 章")));

const wrongSerialization = completeMatrix();
wrongSerialization.slice(0, 3).forEach((value) => { value.book.serialization = "ongoing"; });
assert(evaluateMatrix(wrongSerialization).errors.some((error) => error.includes("12 本已完结")));

const belowNinetyFive = completeMatrix();
belowNinetyFive.slice(6, 11).forEach((value) => { value.observation.result = "parse_failure"; });
assert(evaluateMatrix(belowNinetyFive).errors.some((error) => error.includes("95%")));

const uncachedBelowNinetyFive = completeMatrix();
uncachedBelowNinetyFive.slice(6, 10).forEach((value) => {
    value.observation.cache_saved = false;
});
assert(evaluateMatrix(uncachedBelowNinetyFive).errors.some((error) => error.includes("95%")));

const unsafeLocked = completeMatrix();
const lockedRecord = unsafeLocked.find((value) => value.observation.response === "locked");
lockedRecord.observation.result = "success";
lockedRecord.observation.cache_saved = true;
assert(evaluateMatrix(unsafeLocked).errors.some((error) => error.includes("安全拒绝")));

const missingMalformed = completeMatrix();
missingMalformed.find((value) => value.observation.response === "malformed").observation.response = "other";
assert(evaluateMatrix(missingMalformed).errors.some((error) => error.includes("畸形响应")));

const missingUnknownPua = completeMatrix();
missingUnknownPua.find((value) => value.observation.unknown_pua > 0).observation.unknown_pua = 0;
assert(evaluateMatrix(missingUnknownPua).errors.some((error) => error.includes("未知 PUA")));

const nonActionableReject = completeMatrix();
nonActionableReject.find((value) => value.observation.response === "login_wall")
    .observation.actionable_error = false;
assert(evaluateMatrix(nonActionableReject).errors.some((error) => error.includes("安全拒绝")));

const mixedCommits = completeMatrix();
mixedCommits[0].environment.plugin_commit = "abcdef0";
assert(evaluateMatrix(mixedCommits).errors.some((error) => error.includes("同一个插件候选提交")));

const missingFemale = completeMatrix();
missingFemale.forEach((value) => {
    if (value.book.category === "female") value.book.category = "male";
});
assert(evaluateMatrix(missingFemale).errors.some((error) => error.includes("女频")));

const repeatedPosition = completeMatrix();
repeatedPosition[2].chapter.position = "middle";
assert(evaluateMatrix(repeatedPosition).errors.some((error) => error.includes("前、中、末")));

const inconsistentMetadata = completeMatrix();
inconsistentMetadata[1].book.chapter_count = 31;
assert(evaluateMatrix(inconsistentMetadata).errors.some((error) => error.includes("元数据不一致")));

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "fanqielite-compatibility-"));
try {
    const completePath = path.join(temporary, "complete.jsonl");
    const incompletePath = path.join(temporary, "incomplete.jsonl");
    fs.writeFileSync(completePath, `${matrix.map(JSON.stringify).join("\n")}\n`);
    fs.writeFileSync(incompletePath, `${matrix.slice(0, -1).map(JSON.stringify).join("\n")}\n`);
    const tool = path.join(__dirname, "..", "tools", "compatibility-evidence.js");
    const completeOutput = childProcess.execFileSync(process.execPath,
        [tool, "--require-complete", completePath], { encoding: "utf8" });
    assert(completeOutput.includes("matrix_complete=yes"));
    assert(completeOutput.includes("under_50:5"));
    assert(completeOutput.includes("completed:12,ongoing:18"));
    const incompleteRun = childProcess.spawnSync(process.execPath,
        [tool, "--require-complete", incompletePath], { encoding: "utf8" });
    assert.notStrictEqual(incompleteRun.status, 0, "incomplete matrix passed the CLI gate");
    assert(incompleteRun.stderr.includes("90 个章节场景"));
} finally {
    fs.rmSync(temporary, { recursive: true, force: true });
}

console.log("compatibility evidence tests passed");
