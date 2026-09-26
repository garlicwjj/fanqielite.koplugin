"use strict";

const assert = require("assert");
const pageCandidate = require("../tools/compatibility-page-candidate");
const candidates = require("../tools/compatibility-candidates");

const CANARY = "PRIVATE_TITLE_AUTHOR_BODY_CANARY";
const BOOK_ID = "7654593151348247614";
const SOURCE_URL = `https://fanqienovel.com/page/${BOOK_ID}`;

function html(overrides = {}) {
    const page = Object.assign({
        bookId: BOOK_ID,
        bookName: CANARY,
        author: CANARY,
        description: CANARY,
        chapterTotal: 275,
        creationStatus: 1,
        categoryV2: JSON.stringify([{ Name: "西方奇幻", Gender: 1, MainCategory: true }]),
    }, overrides);
    const state = JSON.stringify({ page });
    return `<html><script>window.__INITIAL_STATE__=${state};</script><p>${CANARY}</p></html>`;
}

const ongoingMale = pageCandidate.buildCandidate(html(), {
    observedAt: "2026-09-26",
    chapterCount: 275,
    sourceUrl: SOURCE_URL,
});
assert.deepStrictEqual(ongoingMale, {
    format: "fanqielite-compatibility-candidate",
    version: 1,
    observed_at: "2026-09-26",
    source_url: SOURCE_URL,
    book: {
        id: BOOK_ID,
        chapter_count: 275,
        serialization: "ongoing",
        category: "male",
    },
});
assert.strictEqual(JSON.stringify(ongoingMale).includes(CANARY), false,
    "page title, author, description, and body must not enter candidate output");
assert.strictEqual(candidates.validateCandidate(ongoingMale), ongoingMale,
    "generated record must pass the existing candidate validator");

const completedFemale = pageCandidate.buildCandidate(html({
    creationStatus: 0,
    categoryV2: JSON.stringify([{ Name: "女频衍生", Gender: 0, MainCategory: true }]),
}), { observedAt: "2026-09-26", chapterCount: 275, sourceUrl: SOURCE_URL });
assert.strictEqual(completedFemale.book.serialization, "completed");
assert.strictEqual(completedFemale.book.category, "female");

const published = pageCandidate.buildCandidate(html({
    creationStatus: 0,
    categoryV2: JSON.stringify([{ Name: "精品小说", Gender: 2, MainCategory: true }]),
}), { observedAt: "2026-09-26", chapterCount: 275, sourceUrl: SOURCE_URL });
assert.strictEqual(published.book.category, "published");

for (const [changed, pattern] of [
    [{ chapterTotal: 274 }, /章数与生产目录解析结果不一致/],
    [{ bookId: "7353209976157899838" }, /书籍 ID 与地址不一致/],
    [{ creationStatus: 2 }, /未知连载状态/],
    [{ categoryV2: "{" + CANARY }, /分类不是有效 JSON/],
    [{ categoryV2: JSON.stringify([]) }, /主分类不唯一/],
    [{ categoryV2: JSON.stringify([{ Name: "未知", Gender: 2, MainCategory: true }]) }, /无法映射/],
]) {
    assert.throws(() => pageCandidate.buildCandidate(html(changed), {
        observedAt: "2026-09-26", chapterCount: 275, sourceUrl: SOURCE_URL,
    }), (error) => {
        assert.strictEqual(error.message.includes(CANARY), false);
        return pattern.test(error.message);
    });
}

for (const [options, pattern] of [
    [{ observedAt: "2026-02-30", chapterCount: 275, sourceUrl: SOURCE_URL }, /观测日期/],
    [{ observedAt: "2026-09-26", chapterCount: 2, sourceUrl: SOURCE_URL }, /3 到 10000/],
    [{ observedAt: "2026-09-26", chapterCount: 275,
        sourceUrl: `https://fanqienovel.com/page/${BOOK_ID}?token=${CANARY}` }, /无查询参数/],
    [{ observedAt: "2026-09-26", chapterCount: 275,
        sourceUrl: `https://fanqienovel.com.attacker.invalid/page/${BOOK_ID}` }, /番茄官网/],
]) {
    assert.throws(() => pageCandidate.buildCandidate(html(), options), (error) => {
        assert.strictEqual(error.message.includes(CANARY), false);
        return pattern.test(error.message);
    });
}

assert.throws(() => pageCandidate.buildCandidate(`<script>window.__INITIAL_STATE__={"page":${CANARY}</script>`, {
    observedAt: "2026-09-26", chapterCount: 275, sourceUrl: SOURCE_URL,
}), (error) => {
    assert.strictEqual(error.message.includes(CANARY), false);
    return /初始状态不完整/.test(error.message);
});
assert.throws(() => pageCandidate.buildCandidate("x".repeat(1024 * 1024 + 1), {
    observedAt: "2026-09-26", chapterCount: 275, sourceUrl: SOURCE_URL,
}), /超过 1 MB/);

assert.deepStrictEqual(pageCandidate.parseArguments(["2026-09-26", "275", SOURCE_URL]), {
    observedAt: "2026-09-26", chapterCount: 275, sourceUrl: SOURCE_URL,
});
assert.throws(() => pageCandidate.parseArguments(["2026-09-26", "27.5", SOURCE_URL]), /必须是整数/);
assert.throws(() => pageCandidate.parseArguments([]), /用法/);

console.log("compatibility page candidate tests passed");
