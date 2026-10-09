#!/usr/bin/env bash
#
# fix-emdash.sh - replace every em dash (U+2014) with a plain hyphen (U+002D)
# in every *.md file under the current directory, recursively.
#
# Works on raw bytes, so file encoding (UTF-8, UTF-16, Latin-1) and line
# endings are preserved. An em dash is the 3-byte sequence E2 80 94.
#
# Binary files, .git internals, dependency folders, and files ignored by
# .gitignore are skipped. Symlinks are not followed.
#
# Usage:
#   ./fix-emdash.sh              # dry run
#   ./fix-emdash.sh --apply      # write changes

set -uo pipefail

# --- Toggle dry run -------------------------------------------------------
# true  = show what would change, write nothing
# false = rewrite files in place
DRY_RUN=true
# -------------------------------------------------------------------------

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true
if [ "$APPLY" = true ]; then DRY_RUN=false; fi

ROOT="$(pwd -P)"

if [ -t 1 ]; then
    C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'; C_OFF=$'\033[0m'
else
    C_CYAN=""; C_YELLOW=""; C_OFF=""
fi

mode="DRY RUN"
[ "$DRY_RUN" = false ] && mode="APPLY"
printf '%sEm dash cleanup - mode: %s - root: %s%s\n' "$C_CYAN" "$mode" "$ROOT" "$C_OFF"

# only files with these extensions are processed
EXTENSIONS=".md"

# true  = skip files matched by .gitignore
# false = process every matching file
RESPECT_GITIGNORE=true

# directories never descended into
SKIP_DIRS=".git .hg .svn node_modules .venv venv vendor dist build .next .cache __pycache__"

# true when $1 (a path relative to $ROOT) sits in a skip dir
is_skipped_dir() {
    local dir
    for dir in ${1//[\\\/]/ }; do
        case " $SKIP_DIRS " in
            *" $dir "*) return 0 ;;
        esac
    done
    return 1
}

# true when the extension of $1 is in $EXTENSIONS, case-insensitive.
# nocasematch is bash 3.1+, and forks nothing like ${var,,} would need on 4+.
# This runs once per candidate file, so it must stay fork-free: shopt -s and
# shopt -u are builtins, and this function owns the flag it toggles, so no
# save/restore of the previous state is needed. Capturing that state with
# $(shopt -p ...) would fork a subshell per call, which cost more than the
# whole rest of the script.
has_wanted_ext() {
    local ext
    shopt -s nocasematch
    for ext in $EXTENSIONS; do
        case "$1" in
            *"$ext") shopt -u nocasematch; return 0 ;;
        esac
    done
    shopt -u nocasematch
    return 1
}

# git pathspec that keeps only the wanted extensions, so git filters instead
# of bash. Without it a work tree with a large ignored tree (node_modules,
# .venv, build output) hands tens of thousands of paths back to be rejected
# one by one in the shell loop.
#
# :(icase) keeps the match case-insensitive, which is what has_wanted_ext used
# to do with nocasematch. The leading * is required: a git pathspec without a
# wildcard matches a path named exactly that. An array, not a joined string:
# a quoted string is not re-parsed on expansion, so git would receive the
# quote characters as part of the pathspec and match nothing.
EXT_PATHSPEC=()
for ext in $EXTENSIONS; do
    EXT_PATHSPEC+=(":(icase)*$ext")
done

# true inside a git work tree
in_git_repo() {
    git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# prints absolute paths NUL-separated.
# inside a work tree with the toggle on, one git call returns every tracked
# and untracked-but-not-ignored file already relative to $ROOT, so the
# .gitignore rules cost nothing per file. Otherwise fall back to find.
list_files() {
    if [ "$RESPECT_GITIGNORE" = true ] && in_git_repo; then
        local rel
        while IFS= read -r -d '' rel; do
            has_wanted_ext "${rel##*/}" || continue
            is_skipped_dir "$rel" && continue
            printf '%s\0' "$ROOT/$rel"
        done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard \
            -- ${EXT_PATHSPEC[@]+"${EXT_PATHSPEC[@]}"})
        return
    fi

    local path
    while IFS= read -r -d '' path; do
        has_wanted_ext "${path##*/}" || continue
        printf '%s\0' "$path"
    done < <(find "$ROOT" \
        \( -name .git -o -name .hg -o -name .svn \
           -o -name node_modules -o -name .venv -o -name venv \
           -o -name vendor -o -name dist -o -name build \
           -o -name .next -o -name .cache -o -name __pycache__ \) -prune \
        -o -type f -print0)
}

# counts ignored files that would otherwise have matched, one git call
count_gitignored() {
    if [ "$RESPECT_GITIGNORE" != true ] || ! in_git_repo; then
        printf '0'
        return
    fi
    local rel n=0
    while IFS= read -r -d '' rel; do
        has_wanted_ext "$rel" || continue
        is_skipped_dir "$rel" && continue
        n=$((n + 1))
    done < <(git -C "$ROOT" ls-files -z --others --ignored --exclude-standard \
        -- ${EXT_PATHSPEC[@]+"${EXT_PATHSPEC[@]}"})
    printf '%d' "$n"
}

# One pass over $1, one process: prints "binary" when a NUL byte appears in the
# first 4 KB, otherwise the number of em dash byte sequences. The shell used to
# do this as is_binary (two head, two wc, one tr, two command substitutions,
# and the same 4 KB read twice) plus count_dashes (a subshell to build the
# pattern, grep, wc, another command substitution): about ten processes and
# three reads per file, against PowerShell's single ReadAllBytes.
scan_file() {
    LC_ALL=C perl -0777 -ne '
        if (index(substr($_, 0, 4096), "\0") >= 0) { print "binary\n"; exit }
        my $p = "\xe2\x80\x94";
        my ($n, $i) = (0, 0);
        while (($i = index($_, $p, $i)) >= 0) { $n++; $i += 3 }
        print "$n\n";
    ' -- "$1" 2>/dev/null
}

changed=0
total_hits=0
scanned=0
skipped=0
gitignored="$(count_gitignored)"

while IFS= read -r -d '' file; do
    rel="${file#"$ROOT"/}"

    scanned=$((scanned + 1))

    if [ ! -r "$file" ]; then
        printf 'unreadable: %s\n' "$file" >&2
        skipped=$((skipped + 1))
        continue
    fi

    # one process per file answers both questions the old two helpers asked
    hits=""
    IFS= read -r hits < <(scan_file "$file")
    case "$hits" in
        binary)
            skipped=$((skipped + 1))
            continue
            ;;
        ''|*[!0-9]*)
            printf 'unreadable: %s\n' "$file" >&2
            skipped=$((skipped + 1))
            continue
            ;;
    esac

    [ "$hits" -eq 0 ] && continue

    changed=$((changed + 1))
    total_hits=$((total_hits + hits))
    printf '%s  %4d  %s%s\n' "$C_YELLOW" "$hits" "$rel" "$C_OFF"

    [ "$DRY_RUN" = true ] && continue

    # temp file in the same directory keeps the rename on one filesystem;
    # cat > keeps the original inode, mode, and owner
    tmp="${file%/*}/.fix-emdash.$$.tmp"
    if ! LC_ALL=C perl -0777 -pe 's/\xe2\x80\x94/-/g' -- "$file" > "$tmp"; then
        printf 'write failed: %s\n' "$rel" >&2
        rm -f "$tmp"
        skipped=$((skipped + 1))
        continue
    fi
    if ! cat "$tmp" > "$file"; then
        printf 'replace failed: %s\n' "$rel" >&2
        skipped=$((skipped + 1))
    fi
    rm -f "$tmp"
done < <(list_files)

printf '\n'
printf '%sFiles scanned : %d%s\n' "$C_CYAN" "$scanned" "$C_OFF"
printf '%sFiles changed : %d%s\n' "$C_CYAN" "$changed" "$C_OFF"
printf '%sEm dashes hit : %d%s\n' "$C_CYAN" "$total_hits" "$C_OFF"
printf '%sSkipped       : %d (binary or unreadable)%s\n' "$C_CYAN" "$skipped" "$C_OFF"
printf '%sGitignored    : %d%s\n' "$C_CYAN" "$gitignored" "$C_OFF"

if [ "$DRY_RUN" = true ]; then
    printf '\n'
    printf '%sDry run only. Set DRY_RUN=false at the top of this script, or pass --apply.%s\n' \
        "$C_CYAN" "$C_OFF"
fi
