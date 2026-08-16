"use strict";

const assert = require("assert");
const { parseJsonLines, summarize, validateRecord } = require("../tools/compatibility-evidence");

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

assert.throws(() => summarize([record(), record()]), /重复/);
assert.throws(() => parseJsonLines("{not json}\n"), /第 1 行/);

console.log("compatibility evidence tests passed");
