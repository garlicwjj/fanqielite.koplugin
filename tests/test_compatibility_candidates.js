"use strict";

const assert = require("assert");
const childProcess = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
    evaluateCandidates,
    parseCandidates,
    validateCandidate,
} = require("../tools/compatibility-candidates");

function candidate(index, chapters, serialization, category) {
    const id = String(8000000000 + index);
    return {
        format: "fanqielite-compatibility-candidate",
        version: 1,
        observed_at: "2026-09-26",
        source_url: `https://fanqienovel.com/page/${id}`,
        book: { id, chapter_count: chapters, serialization, category },
    };
}

function completeCandidates() {
    const bands = [
        { count: 5, chapters: 30 },
        { count: 5, chapters: 100 },
        { count: 8, chapters: 300 },
        { count: 7, chapters: 700 },
        { count: 5, chapters: 1200 },
    ];
    const records = [];
    let index = 0;
    for (const band of bands) {
        for (let offset = 0; offset < band.count; offset += 1) {
            index += 1;
            records.push(candidate(index, band.chapters,
                index <= 12 ? "completed" : "ongoing",
                index === 1 ? "published" : (index % 2 ? "male" : "female")));
        }
    }
    return records;
}

validateCandidate(candidate(1, 30, "completed", "published"));
assert.throws(() => validateCandidate({ ...candidate(1, 30, "completed", "published"), title: "不应记录书名" }), /白名单/);
assert.throws(() => validateCandidate({ ...candidate(1, 30, "completed", "published"), observed_at: "2026-02-31" }), /有效日期/);
assert.throws(() => validateCandidate({ ...candidate(1, 2, "completed", "published") }), /3 到 10000/);
assert.throws(() => validateCandidate({ ...candidate(1, 30, "unknown", "published") }), /serialization/);
assert.throws(() => validateCandidate({ ...candidate(1, 30, "completed", "unknown") }), /category/);
assert.throws(() => validateCandidate({
    ...candidate(1, 30, "completed", "published"),
    source_url: "https://attacker.invalid/page/8000000001",
}), /官网书籍页/);
assert.throws(() => validateCandidate({
    ...candidate(1, 30, "completed", "published"), source_url: {},
}), /官网书籍页/);
assert.throws(() => validateCandidate({
    ...candidate(1, 30, "completed", "published"),
    source_url: "https://fanqienovel.com/page/8000000002",
}), /book.id 一致/);
assert.throws(() => validateCandidate({
    ...candidate(1, 30, "completed", "published"),
    source_url: "https://fanqienovel.com/page/8000000001?token=secret",
}), /官网书籍页/);

const complete = completeCandidates();
const result = evaluateCandidates(complete);
assert.strictEqual(result.complete, true);
assert.strictEqual(result.books, 30);
assert.deepStrictEqual(result.bands, {
    under_50: 5,
    from_50_to_200: 5,
    from_201_to_500: 8,
    from_501_to_1000: 7,
    over_1000: 5,
});
assert.deepStrictEqual(result.serialization, { completed: 12, ongoing: 18 });

const duplicate = complete.slice();
duplicate[29] = duplicate[0];
assert.throws(() => evaluateCandidates(duplicate), /重复书籍 ID/);
assert.strictEqual(evaluateCandidates(complete.slice(0, -1)).complete, false);
const tooMany = completeCandidates();
tooMany.push(candidate(31, 1500, "ongoing", "male"));
assert(evaluateCandidates(tooMany).errors.some((error) => error.includes("恰好 30 本")));
const wrongBand = completeCandidates();
wrongBand[0] = candidate(1, 50, "completed", "published");
assert(evaluateCandidates(wrongBand).errors.some((error) => error.includes("少于 50 章")));
const noPublished = completeCandidates();
noPublished[0] = candidate(1, 30, "completed", "male");
assert(evaluateCandidates(noPublished).errors.some((error) => error.includes("出版候选")));
assert.throws(() => parseCandidates("{not json}\n"), /第 1 行/);

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "fanqielite-candidates-"));
try {
    const completePath = path.join(temporary, "complete.jsonl");
    const incompletePath = path.join(temporary, "incomplete.jsonl");
    fs.writeFileSync(completePath, `${complete.map(JSON.stringify).join("\n")}\n`);
    fs.writeFileSync(incompletePath, `${complete.slice(0, -1).map(JSON.stringify).join("\n")}\n`);
    const tool = path.join(__dirname, "..", "tools", "compatibility-candidates.js");
    const output = childProcess.execFileSync(process.execPath,
        [tool, "--require-complete", completePath], { encoding: "utf8" });
    assert(output.includes("candidate_set_complete=yes"));
    assert(output.includes("under_50:5"));
    const failed = childProcess.spawnSync(process.execPath,
        [tool, "--require-complete", incompletePath], { encoding: "utf8" });
    assert.notStrictEqual(failed.status, 0);
    assert(failed.stderr.includes("恰好 30 本"));
} finally {
    fs.rmSync(temporary, { recursive: true, force: true });
}

console.log("compatibility candidate tests passed");
