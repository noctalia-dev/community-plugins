#!/bin/sh
# Search the unicode tables with fzf; print "rank<TAB>char<TAB>title<TAB>subtitle", best first.
# Usage: search.sh DIR QUERY   (DIR holds the .tsv files written by tools/build_data.py)
#
# Run by mathsym.luau through noctalia.runAsync, because Luau callbacks only get a 25 ms CPU budget.
#
# A query containing a non-ASCII character (a pasted `∀`) is a reverse lookup: names are ASCII, so
# it is unambiguous and goes first. Exact character, then entries that start with it (`∀ᵐ`).
# ASCII characters (`<`) stay ordinary name queries.
#
# Then four fzf passes, all concatenated and de-duplicated by character (first 50 kept):
#   1. names, case-sensitive exact substring. Lean's input method is case-sensitive (`\Go` is
#      omega, `\go` is not), so a hit that differs only in case must not beat e.g. `goal`.
#   2. names, case-insensitive fuzzy (typos, and the case-only matches).
#   3. descriptions, case-insensitive fuzzy; spaces mean AND ("greek lambda").
#   4. code points, exact substring of the hex (`2264`, `U+2264`) or decimal (`8804`) code point.
#      Weakest on purpose: bare numbers are ambiguous with names (`ae` and `1` are Lean names).
#      A leading `U+`, `u+`, `0x` or `\u` is stripped for this pass and means hex only; without
#      one, hex and decimal are searched together.
# Within a pass fzf orders by its score, then shorter text first.

dir=$1
query=$2

# A user's fzf defaults (--height, --tiebreak, ...) must not change how we rank.
FZF_DEFAULT_OPTS=
export FZF_DEFAULT_OPTS
unset FZF_DEFAULT_COMMAND

# `\mathbb{R}`, `mathbb R` and `mathbbR` are the same name; descriptions keep their spaces.
name_query=$(printf '%s' "$query" | tr -d '\\{}[:space:]')
desc_query=$(printf '%s' "$query" | tr -d '\\{}')
[ -n "$name_query" ] || exit 0

# Code-point pass: strip an explicit prefix (which then means hex only), keep only hex digits.
# ASCII-only lowercase on purpose (hex digits and prefixes), hence A-Z rather than [:upper:].
# shellcheck disable=SC2018,SC2019
compact=$(printf '%s' "$name_query" | tr 'A-Z' 'a-z')
hex_only=
case $compact in
    u+*) code_query=${compact#u+}; hex_only=1 ;;
    0x*) code_query=${compact#0x}; hex_only=1 ;;
    u[0-9a-f]*) code_query=${compact#u}; hex_only=1 ;;   # `≤` (the backslash is already gone)
    *)   code_query=$compact ;;
esac
case $code_query in
    '' | *[!0-9a-f]*) code_query= ;;
esac

# fzf in filter mode over "text<TAB>row" lines, matching the text field only.
# --with-nth (not --nth): the length tiebreak must measure just the text, otherwise the digits
# of the row number decide ties and `r!` (row 26) beats the exact name `r` (row 582).
# Usage: fz QUERY [fzf options...] < file
fz() {
    q=$1
    shift
    fzf -f "$q" -d '\t' --with-nth 1 --tiebreak=length,index "$@"
}

# Reverse lookup: "x<TAB>row" lines for data.tsv rows equal to / starting with the query. The query
# goes through the environment because awk -v would process backslash escapes.
char_rows() {
    Q=$(printf '%s' "$query" | tr -d '[:space:]') awk -F'\t' '
        BEGIN { q = ENVIRON["Q"] }
        ($1 "") == (q "") { e[++ne] = NR; next }
        index($1, q) == 1  { p[++np] = NR }
        END {
            for (i = 1; i <= ne; i++) print "x\t" e[i]
            for (i = 1; i <= np; i++) print "x\t" p[i]
        }' "$dir/data.tsv"
}

# Non-ASCII anywhere in the query? ([:print:] is ASCII-only in the C locale.)
non_ascii=
case $(printf '%s' "$query" | LC_ALL=C tr -d '[:print:]') in
    '') ;;
    *) non_ascii=1 ;;
esac

{
    [ -n "$non_ascii" ] && char_rows
    # +x: the query is literal text, not fzf operators, so names like `<=`, `^alpha`, `|-` work.
    fz "$name_query" +x -e +i < "$dir/names.tsv"
    fz "$name_query" +x -i < "$dir/names.tsv"
    fz "$desc_query" -i < "$dir/desc.tsv"
    if [ -n "$code_query" ]; then
        if [ -n "$hex_only" ]; then
            fz "$code_query" -e -i < "$dir/codes_hex.tsv"
        else
            cat "$dir/codes_hex.tsv" "$dir/codes_dec.tsv" | fz "$code_query" -e -i
        fi
    fi
} | awk -F'\t' -v data="$dir/data.tsv" '
    BEGIN {
        while ((getline line < data) > 0) {
            n++
            split(line, f, "\t")
            char[n] = f[1]; title[n] = f[2]; subtitle[n] = f[3]
        }
    }
    !seen[$2]++ {
        if (++rank > 50) exit
        print rank "\t" char[$2] "\t" title[$2] "\t" subtitle[$2]
    }'
