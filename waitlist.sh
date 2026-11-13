#!/usr/bin/env bash
# Commit waitlist: holds GitHub pushes and releases them only on the dates in
# schedule.txt. Each scheduled day gets exactly DAILY_TARGET commits: waiting
# commits first (oldest first), journal commits to fill whatever is left.
# Commits over the target stay on the waitlist for the next scheduled day.
#
#   waitlist.sh run      release the queue + write journal commits (scheduled task calls this)
#   waitlist.sh status   show the schedule, what is done, and what is waiting
#   waitlist.sh hook     called by hooks/pre-push; not for manual use
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULE="${WAITLIST_SCHEDULE:-$ROOT/schedule.txt}"
STATE="${WAITLIST_STATE:-$ROOT/state}"
QUEUE="$STATE/queue.txt"
DONE="$STATE/done.txt"
LOG="$STATE/waitlist.log"
DAILY_TARGET="${WAITLIST_DAILY_TARGET:-4}"         # commits per scheduled day, no more, no less
URL_PATTERN="${WAITLIST_URL_PATTERN:-github\.com}" # only pushes to matching remotes are held
REAL_TODAY="$(date +%F)"
TODAY="${WAITLIST_TODAY:-$REAL_TODAY}"
TAB="$(printf '\t')"
RELEASED=0                                         # set by release_entry

mkdir -p "$STATE"
touch "$QUEUE" "$DONE"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
dates() { grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$SCHEDULE" | sort -u; }
is_pdate() { dates | grep -qx "$1"; }
next_pdate() { dates | awk -v t="$TODAY" '$0 >= t { print; exit }'; }
last_pdate() { dates | awk -v t="$TODAY" '$0 <= t { d = $0 } END { print d }'; }

# Timestamp to put on a commit that should count on day $1.
stamp_for() {
  if [ "$1" = "$REAL_TODAY" ]; then date '+%F %T'; else echo "$1 12:00:00"; fi
}

# How many commits have already been put on day $1.
used_on() { cat "$STATE/count-$1" 2>/dev/null || echo 0; }
add_used() { echo $(( $(used_on "$1") + $2 )) > "$STATE/count-$1"; }

# ---------------------------------------------------------------- pre-push hook
cmd_hook() {
  local remote="${1:-}" url="${2:-}"
  if [ -n "${WAITLIST_RELEASE:-}" ] || [ -n "${WAITLIST_BYPASS:-}" ]; then exit 0; fi
  echo "$url" | grep -qE "$URL_PATTERN" || exit 0

  local repo queued=0 lref lsha rref rsha entry
  repo="$(git rev-parse --show-toplevel)"
  while read -r lref lsha rref rsha; do
    case "$lsha" in *[!0]*) ;; *) continue ;; esac          # branch deletion
    case "$rref" in refs/heads/*) ;; *) continue ;; esac     # tags etc.
    if [ "$lref" = "HEAD" ]; then lref="$(git symbolic-ref -q HEAD || true)"; fi
    case "$lref" in
      refs/heads/*) ;;
      *) echo "waitlist: push a branch by name (not a raw commit) so it can be queued." >&2; exit 1 ;;
    esac
    entry="$repo$TAB$remote$TAB$lref$TAB$rref"
    grep -qxF "$entry" "$QUEUE" || echo "$entry" >> "$QUEUE"
    queued=1
  done
  [ "$queued" = 1 ] || exit 0

  local next; next="$(next_pdate)"
  {
    echo ""
    echo "waitlist: push held. $repo is on the waitlist."
    if [ -z "$next" ]; then
      echo "waitlist: no scheduled dates remain - push with WAITLIST_BYPASS=1 or uninstall."
    else
      echo "waitlist: next release day is $next ($DAILY_TARGET commits per day, oldest first)."
    fi
    echo "waitlist: to push right now anyway:  WAITLIST_BYPASS=1 git push"
    echo ""
  } >&2
  exit 1
}

# ------------------------------------------------------------- release one ref
# release_entry REPO REMOTE LOCALREF REMOTEREF STAMP [LIMIT]
# Pushes the oldest LIMIT commits the remote does not have yet (0 = all of them),
# re-dated to STAMP unless they already fall on a scheduled day. Later commits
# stay local with their dates untouched. Sets RELEASED to the number pushed.
# Returns 0 when nothing is left to push, non-zero when the entry must stay queued.
release_entry() {
  local repo="$1" remote="$2" lref="$3" rref="$4" stamp="$5" limit="${6:-0}"
  RELEASED=0
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    log "drop  $repo (not a git repo any more)"; return 0
  fi
  local tip; tip="$(git -C "$repo" rev-parse -q --verify "$lref")" || {
    log "drop  $repo $lref (branch no longer exists)"; return 0; }

  local -a list=()
  mapfile -t list < <(git -C "$repo" rev-list --reverse --topo-order "$tip" --not --remotes="$remote")
  local total="${#list[@]}" k
  [ "$total" -gt 0 ] || return 0
  k="$total"
  if [ "$limit" -gt 0 ] && [ "$total" -gt "$limit" ]; then k="$limit"; fi

  local -A map=()
  local c p new tree aday ad cd msg i=0
  local -a parents pargs
  msg="$(mktemp)"
  for c in "${list[@]}"; do
    tree="$(git -C "$repo" rev-parse "$c^{tree}")"
    read -r -a parents <<< "$(git -C "$repo" rev-list --parents -n 1 "$c" | cut -s -d' ' -f2-)"
    pargs=()
    for p in "${parents[@]}"; do pargs+=(-p "${map[$p]:-$p}"); done
    aday="$(git -C "$repo" log -1 --format=%ad --date=format:%Y-%m-%d "$c")"
    if [ "$i" -ge "$k" ] || is_pdate "$aday"; then
      ad="$(git -C "$repo" log -1 --format=%aI "$c")"
      cd="$(git -C "$repo" log -1 --format=%cI "$c")"
    else
      ad="$stamp"; cd="$stamp"
    fi
    git -C "$repo" cat-file commit "$c" | sed '1,/^$/d' > "$msg"
    new="$(GIT_AUTHOR_NAME="$(git -C "$repo" log -1 --format=%an "$c")" \
           GIT_AUTHOR_EMAIL="$(git -C "$repo" log -1 --format=%ae "$c")" \
           GIT_COMMITTER_NAME="$(git -C "$repo" log -1 --format=%cn "$c")" \
           GIT_COMMITTER_EMAIL="$(git -C "$repo" log -1 --format=%ce "$c")" \
           GIT_AUTHOR_DATE="$ad" GIT_COMMITTER_DATE="$cd" \
           git -C "$repo" commit-tree "$tree" "${pargs[@]}" -F "$msg")" || {
      rm -f "$msg"; log "FAIL  $repo: could not rewrite $c"; return 1; }
    map[$c]="$new"
    i=$((i + 1))
  done
  rm -f "$msg"

  local newtip="${map[$tip]:-$tip}"
  if [ "$newtip" != "$tip" ]; then
    git -C "$repo" update-ref -m "waitlist: re-date for release" "$lref" "$newtip" "$tip" || {
      log "FAIL  $repo: could not move $lref"; return 1; }
  fi
  local pushsha="${map[${list[$((k - 1))]}]}"
  if ! WAITLIST_RELEASE=1 git -C "$repo" push -q "$remote" "$pushsha:$rref" >>"$LOG" 2>&1; then
    log "FAIL  push $repo ${lref#refs/heads/} -> $remote (kept on the waitlist, see log above)"
    return 1
  fi
  RELEASED="$k"
  log "push  $repo ${lref#refs/heads/} -> $remote ($k of $total commit(s))"
  [ "$k" -eq "$total" ]
}

# ------------------------------------------------------------------------- run
cmd_run() {
  local d i n stamp budget

  # 1. On a scheduled day, release waiting commits (oldest first) up to the daily target.
  if is_pdate "$TODAY"; then
    stamp="$(stamp_for "$TODAY")"
    local keep repo remote lref rref
    keep="$(mktemp)"
    while IFS="$TAB" read -r repo remote lref rref; do
      [ -n "$repo" ] || continue
      budget=$(( DAILY_TARGET - $(used_on "$TODAY") ))
      if [ "$budget" -le 0 ]; then
        echo "$repo$TAB$remote$TAB$lref$TAB$rref" >> "$keep"; continue
      fi
      release_entry "$repo" "$remote" "$lref" "$rref" "$stamp" "$budget" \
        || echo "$repo$TAB$remote$TAB$lref$TAB$rref" >> "$keep"
      add_used "$TODAY" "$RELEASED"
    done < "$QUEUE"
    mv "$keep" "$QUEUE"
  fi

  # 2. Journal commits fill each scheduled day up to the target. A day missed
  #    because the PC was off is back-filled with that day's date.
  for d in $(dates); do
    [[ "$d" > "$TODAY" ]] && break
    grep -qx "$d" "$DONE" && continue
    n=$(( DAILY_TARGET - $(used_on "$d") ))
    [ "$n" -gt 0 ] || n=0
    mkdir -p "$ROOT/journal"
    for i in $(seq 1 "$n"); do
      if [ "$d" = "$REAL_TODAY" ]; then stamp="$(date '+%F %T')"
      else stamp="$d 12:$(printf '%02d' "$i"):00"; fi
      [ -f "$ROOT/journal/$d.md" ] || echo "# $d" > "$ROOT/journal/$d.md"
      echo "- entry $i of $n" >> "$ROOT/journal/$d.md"
      git -C "$ROOT" add "journal/$d.md" 2>/dev/null
      GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" \
        git -C "$ROOT" commit -q -m "journal: $d ($i/$n)" -- "journal/$d.md" || {
          log "FAIL  journal commit for $d"; return 1; }
    done
    add_used "$d" "$n"
    echo "$d" >> "$DONE"
    log "wrote $n journal commit(s) for $d ($(used_on "$d") total that day)"
  done

  # 3. Push this repo's journal commits (they are already dated to scheduled days).
  local branch last
  branch="$(git -C "$ROOT" symbolic-ref -q HEAD || true)"
  last="$(last_pdate)"
  if [ -n "$last" ] && [ -n "$branch" ]; then
    if ! git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
      log "WARN  $ROOT has no 'origin' remote yet - journal commits are local only"
    elif [ -n "$(git -C "$ROOT" rev-list -n 1 "$branch" --not --remotes=origin)" ]; then
      release_entry "$ROOT" origin "$branch" "$branch" "$(stamp_for "$last")" 0
    fi
  fi

  is_pdate "$TODAY" || log "today ($TODAY) is not a scheduled day; $(grep -c . "$QUEUE") branch(es) waiting, next release $(next_pdate)"
}

cmd_status() {
  local d mark
  echo "Today: $TODAY    next scheduled day: $(next_pdate)    commits per day: $DAILY_TARGET"
  echo
  for d in $(dates); do
    if grep -qx "$d" "$DONE"; then mark="done ($(used_on "$d") commits)"
    elif [[ "$d" < "$TODAY" ]]; then mark="MISSED (next run back-fills it)"
    elif [ "$d" = "$TODAY" ]; then mark="today"
    else mark="-"; fi
    echo "  $d $(date -d "$d" +%a)  $mark"
  done
  echo
  echo "Waiting branches: $(grep -c . "$QUEUE")"
  local repo remote lref rref
  while IFS="$TAB" read -r repo remote lref rref; do
    [ -n "$repo" ] || continue
    echo "  $repo [${lref#refs/heads/} -> $remote]  $(git -C "$repo" rev-list --count "$lref" --not --remotes="$remote" 2>/dev/null || echo '?') commit(s) waiting"
  done < "$QUEUE"
}

case "${1:-}" in
  run) cmd_run ;;
  status) cmd_status ;;
  hook) shift; cmd_hook "$@" ;;
  *) echo "usage: waitlist.sh run | status" >&2; exit 2 ;;
esac
