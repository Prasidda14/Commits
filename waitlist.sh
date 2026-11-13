#!/usr/bin/env bash
# Commit waitlist: holds GitHub pushes and releases them only on the dates in
# schedule.txt, topping each of those days up with journal commits.
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
MIN_COMMITS="${WAITLIST_MIN_COMMITS:-6}"          # journal commits per scheduled day
URL_PATTERN="${WAITLIST_URL_PATTERN:-github\.com}" # only pushes to matching remotes are held
REAL_TODAY="$(date +%F)"
TODAY="${WAITLIST_TODAY:-$REAL_TODAY}"
TAB="$(printf '\t')"

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
    elif [ "$next" = "$TODAY" ]; then
      echo "waitlist: today is a scheduled day - run '$ROOT/waitlist.sh run' to push it now."
    else
      echo "waitlist: it will be pushed automatically on $next."
    fi
    echo "waitlist: to push right now anyway:  WAITLIST_BYPASS=1 git push"
    echo ""
  } >&2
  exit 1
}

# ------------------------------------------------------------- release one ref
# Re-dates every commit the remote does not have yet (unless it already falls on
# a scheduled day) to $5, then pushes. Returns 0 if the queue entry is finished.
release_entry() {
  local repo="$1" remote="$2" lref="$3" rref="$4" stamp="$5"
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    log "drop  $repo (not a git repo any more)"; return 0
  fi
  local tip; tip="$(git -C "$repo" rev-parse -q --verify "$lref")" || {
    log "drop  $repo $lref (branch no longer exists)"; return 0; }

  local -A map=()
  local c p new tree aday ad cd msg n=0
  local -a parents pargs
  msg="$(mktemp)"
  while read -r c; do
    [ -n "$c" ] || continue
    tree="$(git -C "$repo" rev-parse "$c^{tree}")"
    read -r -a parents <<< "$(git -C "$repo" rev-list --parents -n 1 "$c" | cut -s -d' ' -f2-)"
    pargs=()
    for p in "${parents[@]}"; do pargs+=(-p "${map[$p]:-$p}"); done
    aday="$(git -C "$repo" log -1 --format=%ad --date=format:%Y-%m-%d "$c")"
    if is_pdate "$aday"; then
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
    n=$((n + 1))
  done < <(git -C "$repo" rev-list --reverse --topo-order "$tip" --not --remotes="$remote")
  rm -f "$msg"

  local newtip="${map[$tip]:-$tip}"
  if [ "$newtip" != "$tip" ]; then
    git -C "$repo" update-ref -m "waitlist: re-date for release" "$lref" "$newtip" "$tip" || {
      log "FAIL  $repo: could not move $lref"; return 1; }
  fi
  if WAITLIST_RELEASE=1 git -C "$repo" push -q "$remote" "$lref:$rref" >>"$LOG" 2>&1; then
    log "push  $repo ${lref#refs/heads/} -> $remote ($n commit(s))"
    return 0
  fi
  log "FAIL  push $repo ${lref#refs/heads/} -> $remote (kept on the waitlist, see log above)"
  return 1
}

# ------------------------------------------------------------------------- run
cmd_run() {
  local d i stamp

  # 1. Journal commits for every scheduled day up to today that has none yet.
  #    A day missed because the PC was off is back-filled with that day's date.
  for d in $(dates); do
    [[ "$d" > "$TODAY" ]] && break
    grep -qx "$d" "$DONE" && continue
    mkdir -p "$ROOT/journal"
    for i in $(seq 1 "$MIN_COMMITS"); do
      if [ "$d" = "$REAL_TODAY" ]; then stamp="$(date '+%F %T')"
      else stamp="$d 12:$(printf '%02d' "$i"):00"; fi
      [ -f "$ROOT/journal/$d.md" ] || echo "# $d" > "$ROOT/journal/$d.md"
      echo "- entry $i of $MIN_COMMITS" >> "$ROOT/journal/$d.md"
      git -C "$ROOT" add "journal/$d.md"
      GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" \
        git -C "$ROOT" commit -q -m "journal: $d ($i/$MIN_COMMITS)" -- "journal/$d.md" || {
          log "FAIL  journal commit for $d"; return 1; }
    done
    echo "$d" >> "$DONE"
    log "wrote $MIN_COMMITS journal commit(s) for $d"
  done

  # 2. Push this repo if it has anything the remote lacks.
  local branch last
  branch="$(git -C "$ROOT" symbolic-ref -q HEAD || true)"
  last="$(last_pdate)"
  if [ -n "$last" ] && [ -n "$branch" ]; then
    if ! git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
      log "WARN  $ROOT has no 'origin' remote yet - journal commits are local only"
    elif [ -n "$(git -C "$ROOT" rev-list -n 1 "$branch" --not --remotes=origin)" ]; then
      release_entry "$ROOT" origin "$branch" "$branch" "$(stamp_for "$last")"
    fi
  fi

  # 3. Release the waitlist - only on a scheduled day.
  if ! is_pdate "$TODAY"; then
    log "today ($TODAY) is not a scheduled day; $(grep -c . "$QUEUE") push(es) waiting, next release $(next_pdate)"
    return 0
  fi
  stamp="$(stamp_for "$TODAY")"
  local keep repo remote lref rref
  keep="$(mktemp)"
  while IFS="$TAB" read -r repo remote lref rref; do
    [ -n "$repo" ] || continue
    release_entry "$repo" "$remote" "$lref" "$rref" "$stamp" \
      || echo "$repo$TAB$remote$TAB$lref$TAB$rref" >> "$keep"
  done < "$QUEUE"
  mv "$keep" "$QUEUE"
}

cmd_status() {
  local d mark
  echo "Today: $TODAY    next scheduled day: $(next_pdate)"
  echo
  for d in $(dates); do
    if grep -qx "$d" "$DONE"; then mark="done"
    elif [[ "$d" < "$TODAY" ]]; then mark="MISSED (next run back-fills it)"
    elif [ "$d" = "$TODAY" ]; then mark="today"
    else mark="-"; fi
    echo "  $d $(date -d "$d" +%a)  $mark"
  done
  echo
  echo "Waiting pushes: $(grep -c . "$QUEUE")"
  awk -F'\t' 'NF { sub("refs/heads/", "", $3); print "  " $1 "  [" $3 " -> " $2 "]" }' "$QUEUE"
}

case "${1:-}" in
  run) cmd_run ;;
  status) cmd_status ;;
  hook) shift; cmd_hook "$@" ;;
  *) echo "usage: waitlist.sh run | status" >&2; exit 2 ;;
esac
