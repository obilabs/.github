# hygiene-lib.sh - shared helpers for the ObiLabs git hygiene hooks.
#
# Sourced by pre-commit, commit-msg and pre-push; never executed directly.
# POSIX sh only (runs under Git for Windows' sh, dash, and macOS sh).
# Canonical source: obilabs/.github, tooling/git-hooks/.

HYG_ALLOW_MARKER='hygiene:allow'

hyg_err() { printf '%s\n' "$*" >&2; }

hyg_config_dir() { printf '%s\n' "${OBILABS_CONFIG_DIR:-$HOME/.config/obilabs}"; }

hyg_denylist_file() {
  printf '%s\n' "${OBILABS_HYGIENE_DENYLIST:-$(hyg_config_dir)/hygiene-denylist}"
}

hyg_skip_requested() { [ "${OBILABS_HYGIENE_SKIP:-}" = "1" ]; }

hyg_warn_skip() {
  hyg_err ""
  hyg_err "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  hyg_err "!! OBILABS_HYGIENE_SKIP=1: $1 hygiene checks were SKIPPED."
  hyg_err "!! Nothing was scanned. CI (hygiene.yml) will still check this work."
  hyg_err "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  hyg_err ""
}

# Personal webmail identities that must never be baked into commit metadata.
hyg_is_personal_email() {
  printf '%s\n' "$1" | grep -iqE '@(gmail|googlemail)\.com>?[[:space:]]*$'
}

# Rules: one per line, "<label> <extended regex>" (label has no spaces).
# The path rules are mirrored in .github/workflows/hygiene.yml; the test suite
# fails if the two copies drift.
hyg_secret_rules() {
  cat <<'EOF'
private-key -----BEGIN [A-Z ]*PRIVATE KEY-----
aws-access-key-id AKIA[0-9A-Z]{16}
github-classic-token ghp_[A-Za-z0-9]{36}
github-fine-grained-token github_pat_[A-Za-z0-9_]{20,}
slack-token xox[baprs]-[A-Za-z0-9-]{10,}
google-api-key AIza[0-9A-Za-z_-]{35}
anthropic-api-key sk-ant-[A-Za-z0-9_-]{20,}
openai-style-api-key (^|[^A-Za-z0-9_-])sk-[A-Za-z0-9]{32,}
EOF
}

hyg_path_rules() {
  cat <<'EOF'
# BEGIN path-rules
windows-user-home [A-Za-z]:[\/]Users[\/]
macos-user-home (^|[^A-Za-z0-9._-])/Users/[^ /]+/
linux-user-home (^|[^A-Za-z0-9._-])/home/[^ /]+/
# END path-rules
EOF
}

# Read a unified diff on stdin; write added lines to <prefix>.txt and their
# "path:line" locations to <prefix>.loc (same line order). Lines carrying the
# allow marker are dropped.
hyg_split_added_lines() {
  : >"$1.txt"
  : >"$1.loc"
  awk -v loc="$1.loc" -v txt="$1.txt" -v marker="$HYG_ALLOW_MARKER" '
    /^diff --git / { hdr = 1; file = ""; next }
    hdr && /^\+\+\+ / {
      f = substr($0, 5)
      if (substr(f, 1, 2) == "b/") f = substr(f, 3)
      file = f
      next
    }
    /^@@ / {
      hdr = 0
      s = $0
      sub(/^@@ -[0-9,]* \+/, "", s)
      sub(/[ ,].*$/, "", s)
      ln = s + 0
      next
    }
    hdr { next }
    /^\+/ {
      c = substr($0, 2)
      if (index(c, marker) == 0) { print file ":" ln > loc; print c > txt }
      ln++
      next
    }
  '
}

# hyg_scan_rules <prefix> <rules-function>
# Prints "  path:line  [label]" for every hit; returns 1 if anything matched.
hyg_scan_rules() {
  _prefix=$1
  _hits=0
  _rules=$($2)
  # Fast path (process spawns are slow on Windows): one grep over all rules,
  # and per-rule labelling only when something matched.
  printf '%s\n' "$_rules" | sed -n 's/^[^# ][^ ]* //p' >"$_prefix.rules"
  grep -q -E -f "$_prefix.rules" "$_prefix.txt"
  case $? in
    0) ;;
    1) return 0 ;;
    *) printf '  scanner error (grep failed); failing closed\n' >&2; return 1 ;;
  esac
  while IFS=' ' read -r _label _re; do
    case $_label in '' | '#'*) continue ;; esac
    _nums=$(grep -n -E -e "$_re" "$_prefix.txt" 2>/dev/null | cut -d: -f1)
    for _n in $_nums; do
      printf '  %s  [%s]\n' "$(sed -n "${_n}p" "$_prefix.loc")" "$_label" >&2
      _hits=1
    done
  done <<EOF
$_rules
EOF
  return $_hits
}

# hyg_scan_denylist <prefix> - fixed-string, case-insensitive entries from the
# user-local denylist file (never committed anywhere).
hyg_scan_denylist() {
  _dl=$(hyg_denylist_file)
  [ -f "$_dl" ] || return 0
  _pat="$1.deny"
  tr -d '\r' <"$_dl" | grep -v -E '^[[:space:]]*(#|$)' >"$_pat" || true
  [ -s "$_pat" ] || return 0
  # awk rather than "grep -i -F": Git for Windows' grep 3.0 aborts on -i with -F.
  _nums=$(awk -v pats="$_pat" '
    BEGIN { while ((getline p < pats) > 0) list[++np] = tolower(p) }
    { l = tolower($0); for (i = 1; i <= np; i++) if (index(l, list[i])) { print NR; next } }
  ' "$1.txt")
  [ -n "$_nums" ] || return 0
  for _n in $_nums; do
    printf '  %s  [denylist entry]\n' "$(sed -n "${_n}p" "$1.loc")" >&2
  done
  return 1
}

# Emails on commits in a revision range that are personal webmail.
# Args are passed to git log (e.g. "base..head" or "sha --not --remotes").
hyg_bad_identity_commits() {
  git log --format='%h%x09%ae%x09%ce' "$@" | awk -F'\t' '
    tolower($2) ~ /@(gmail|googlemail)\.com$/ || tolower($3) ~ /@(gmail|googlemail)\.com$/ {
      print "  " $1 "  author=" $2 "  committer=" $3
    }'
}

hyg_ai_trailer_commits() {
  git log --format='%x01%h%n%B' "$@" | awk '
    substr($0, 1, 1) == "\001" { h = substr($0, 2); next }
    {
      l = tolower($0)
      if ((l ~ /^co-authored-by:.*(claude|anthropic)/ || l ~ /generated with .*claude code/) && !(h in seen)) {
        seen[h] = 1
        print "  " h
      }
    }'
}

# Run the repository's own hook (<common-git-dir>/hooks/<name>) if present, so a
# global core.hooksPath does not silently disable per-repo hooks. Stdin and
# arguments pass straight through; its exit status is returned.
hyg_chain() {
  _name=$1
  shift
  _common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  _target="$_common/hooks/$_name"
  [ -f "$_target" ] && [ -x "$_target" ] || return 0
  _tdir=$(CDPATH='' cd -- "$_common/hooks" && pwd -P) || return 0
  [ "$_tdir" = "$HYG_DIR" ] && return 0
  "$_target" "$@"
}
