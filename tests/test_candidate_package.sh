#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/fanqielite-package-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

FANQIELITE_ALLOW_DIRTY=1 FANQIELITE_DIST_DIR="$test_root/dist" \
    "$repo_root/tools/build-candidate.sh" >/dev/null

archive=$(find "$test_root/dist" -type f -name 'fanqielite-koreader-candidate-*.zip')
checksum="$archive.sha256"
test -f "$archive"
test -f "$checksum"
archive_name=$(basename "$archive")
expected_archive_name="fanqielite-koreader-candidate-$(git -C "$repo_root" rev-parse --short=12 HEAD).zip"
test "$archive_name" = "$expected_archive_name"

archive_bytes=$(wc -c < "$archive" | tr -d ' ')
test "$archive_bytes" -gt 0
test "$archive_bytes" -le 1048576

if command -v shasum >/dev/null 2>&1; then
    actual_hash=$(shasum -a 256 "$archive" | awk '{print $1}')
else
    actual_hash=$(sha256sum "$archive" | awk '{print $1}')
fi
expected_hash=$(awk 'NR == 1 {print $1}' "$checksum")
test "$actual_hash" = "$expected_hash"
test "$(awk 'NR == 1 {print $2}' "$checksum")" = "$archive_name"

cat > "$test_root/expected.txt" <<'EOF'
fanqielite.koplugin/
fanqielite.koplugin/BUILD-INFO.txt
fanqielite.koplugin/CHANGELOG.md
fanqielite.koplugin/INSTALL.md
fanqielite.koplugin/LICENSE
fanqielite.koplugin/README.md
fanqielite.koplugin/_meta.lua
fanqielite.koplugin/docs/
fanqielite.koplugin/docs/EPHEMERAL_HTTP_AUDIT.md
fanqielite.koplugin/docs/QUALITY_PLAN.md
fanqielite.koplugin/docs/QR_THREAT_MODEL.md
fanqielite.koplugin/docs/SUBPROCESS_SECURITY_AUDIT.md
fanqielite.koplugin/docs/TLS_SECURITY_AUDIT.md
fanqielite.koplugin/docs/bookshelf-format.md
fanqielite.koplugin/docs/compatibility-matrix.md
fanqielite.koplugin/fanqielite/
fanqielite.koplugin/fanqielite/export.lua
fanqielite.koplugin/fanqielite/ephemeral_session.lua
fanqielite.koplugin/fanqielite/ephemeral_task.lua
fanqielite.koplugin/fanqielite/ephemeral_http.lua
fanqielite.koplugin/fanqielite/ephemeral_import_task.lua
fanqielite.koplugin/fanqielite/ephemeral_result.lua
fanqielite.koplugin/fanqielite/http.lua
fanqielite.koplugin/fanqielite/import.lua
fanqielite.koplugin/fanqielite/library.lua
fanqielite.koplugin/fanqielite/networktask.lua
fanqielite.koplugin/fanqielite/parser.lua
fanqielite.koplugin/fanqielite/persistence.lua
fanqielite.koplugin/fanqielite/pua.lua
fanqielite.koplugin/fanqielite/qrdisplay.lua
fanqielite.koplugin/fanqielite/search.lua
fanqielite.koplugin/fanqielite/storage.lua
fanqielite.koplugin/fanqielite/verified_tls.lua
fanqielite.koplugin/main.lua
EOF
unzip -Z1 "$archive" | LC_ALL=C sort > "$test_root/actual.txt"
LC_ALL=C sort "$test_root/expected.txt" -o "$test_root/expected.txt"
diff -u "$test_root/expected.txt" "$test_root/actual.txt"

unzip -q "$archive" -d "$test_root/unpacked"
plugin_root="$test_root/unpacked/fanqielite.koplugin"
test -s "$plugin_root/_meta.lua"
test -s "$plugin_root/main.lua"
test -s "$plugin_root/INSTALL.md"
test "$(sed -n 's/^commit=//p' "$plugin_root/BUILD-INFO.txt")" = "$(git -C "$repo_root" rev-parse HEAD)"
grep -Eq '^worktree=(clean|dirty)$' "$plugin_root/BUILD-INFO.txt"
grep -Fqx 'status=candidate-test-not-release' "$plugin_root/BUILD-INFO.txt"
test -s "$plugin_root/docs/bookshelf-format.md"
test -s "$plugin_root/docs/EPHEMERAL_HTTP_AUDIT.md"
test -s "$plugin_root/docs/compatibility-matrix.md"
test -s "$plugin_root/docs/QUALITY_PLAN.md"
test -s "$plugin_root/docs/QR_THREAT_MODEL.md"
test -s "$plugin_root/docs/SUBPROCESS_SECURITY_AUDIT.md"
test -s "$plugin_root/docs/TLS_SECURITY_AUDIT.md"

if command -v luac5.1 >/dev/null 2>&1; then
    find "$plugin_root" -type f -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p
elif command -v luajit >/dev/null 2>&1; then
    find "$plugin_root" -type f -name '*.lua' -exec luajit -b '{}' /dev/null \;
else
    echo "Lua 5.1 or LuaJIT is required to validate candidate package syntax" >&2
    exit 1
fi

grep -Fq 'koreader/plugins/fanqielite.koplugin' "$plugin_root/INSTALL.md"
grep -Fq 'koreader/settings/fanqielite.lua' "$plugin_root/INSTALL.md"
grep -Fq 'koreader/fanqielite' "$plugin_root/INSTALL.md"
grep -Fq '同一份升级前备份' "$plugin_root/INSTALL.md"
grep -Fq '候选测试包' "$plugin_root/INSTALL.md"

printf '%s\n' "candidate package tests passed"
