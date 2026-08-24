#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir=${FANQIELITE_DIST_DIR:-"$repo_root/dist"}
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/fanqielite-candidate.XXXXXX")
trap 'rm -rf "$stage_root"' EXIT HUP INT TERM

command -v zip >/dev/null 2>&1 || {
    echo "zip is required to build the candidate package" >&2
    exit 1
}

commit=$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null) || {
    echo "candidate package must be built from a Git checkout" >&2
    exit 1
}
short_commit=$(git -C "$repo_root" rev-parse --short=12 HEAD)
worktree_state=clean
if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]; then
    worktree_state=dirty
    if [ "${FANQIELITE_ALLOW_DIRTY:-0}" != "1" ]; then
        echo "refusing to build a candidate package from an uncommitted worktree" >&2
        exit 1
    fi
fi

plugin_root="$stage_root/fanqielite.koplugin"
mkdir -p "$plugin_root/fanqielite" "$plugin_root/docs"

for file in _meta.lua main.lua LICENSE README.md INSTALL.md CHANGELOG.md; do
    COPYFILE_DISABLE=1 cp -p "$repo_root/$file" "$plugin_root/$file"
done
for module in "$repo_root"/fanqielite/*.lua; do
    COPYFILE_DISABLE=1 cp -p "$module" "$plugin_root/fanqielite/"
done
for document in bookshelf-format.md compatibility-matrix.md QR_THREAT_MODEL.md QUALITY_PLAN.md; do
    COPYFILE_DISABLE=1 cp -p "$repo_root/docs/$document" "$plugin_root/docs/$document"
done
printf 'commit=%s\nworktree=%s\nstatus=candidate-test-not-release\n' \
    "$commit" "$worktree_state" > "$plugin_root/BUILD-INFO.txt"

archive_name="fanqielite-koreader-candidate-$short_commit.zip"
archive="$stage_root/$archive_name"
(cd "$stage_root" && zip -X -q -r "$archive" fanqielite.koplugin)

archive_bytes=$(wc -c < "$archive" | tr -d ' ')
if [ "$archive_bytes" -gt 1048576 ]; then
    echo "candidate package exceeds the 1 MB limit" >&2
    exit 1
fi

if command -v shasum >/dev/null 2>&1; then
    archive_hash=$(shasum -a 256 "$archive" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
    archive_hash=$(sha256sum "$archive" | awk '{print $1}')
else
    echo "shasum or sha256sum is required to create the checksum" >&2
    exit 1
fi
printf '%s  %s\n' "$archive_hash" "$archive_name" > "$stage_root/$archive_name.sha256"

mkdir -p "$dist_dir"
mv -f "$archive" "$dist_dir/$archive_name"
mv -f "$stage_root/$archive_name.sha256" "$dist_dir/$archive_name.sha256"

printf '%s\n' "$dist_dir/$archive_name"
