#!/usr/bin/env bash
# Commit waitlist: holds GitHub pushes and releases them only on the dates in
# schedule.txt. Each scheduled day gets exactly DAILY_TARGET commits, in this order:
#   1. waiting commits from other repos, oldest first (at most DAILY_TARGET - 1)
#   2. waiting edits to this repo itself
#   3. notes (one commit per recorded commit/push from other repos)
#   4. journal filler for whatever is left
# Anything over the target stays on the waitlist for the next scheduled day.
#
#   waitlist.sh run      release the queue + write journal commits (scheduled task calls this)
#   waitlist.sh status   show the schedule, what is done, and what is waiting
#   waitlist.sh list     show every waiting commit, grouped by repo (also kept in QUEUE.md)
#   waitlist.sh hook     called by hooks/pre-push; not for manual use
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULE="${WAITLIST_SCHEDULE:-$ROOT/schedule.txt}"
STATE="${WAITLIST_STATE:-$ROOT/state}"
QUEUE="$STATE/queue.txt"
DONE="$STATE/done.txt"
LOG="$STATE/waitlist.log"
DAILY_TARGET="${WAITLIST_DAILY_TARGET:-8}"         # commits per scheduled day, no more, no less
URL_PATTERN="${WAITLIST_URL_PATTERN:-github\.com}" # only pushes to matching remotes are held
REAL_TODAY="$(date +%F)"
TODAY="${WAITLIST_TODAY:-$REAL_TODAY}"
TAB="$(printf '\t')"
RELEASED=0                                         # set by release_entry

mkdir -p "$STATE"
NOTES="$STATE/notes-pending.txt"                    # notes not yet committed, one per line
SEEN="$STATE/notes-seen.txt"
touch "$QUEUE" "$DONE" "$NOTES" "$SEEN"

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

# Commits the scheduler writes itself; they are already dated to a scheduled day.
SCHED_RE='^(journal|notes): '

# Unpushed commits in this repo that the scheduler did not write (edits to the tool).
root_extra() {
  git -C "$ROOT" log --format=%s HEAD --not --remotes=origin 2>/dev/null | grep -cvE "$SCHED_RE"
}

# add_note KIND REPO BRANCH SHA TEXT - remember one commit or held push so a
# note about it can be committed to the notes file on a scheduled day. Once per KIND+SHA.
add_note() {
  local key="$1$TAB$2$TAB$4"
  grep -qxF "$key" "$SEEN" && return 0
  echo "$key" >> "$SEEN"
  echo "$(date '+%F %H:%M')$TAB$1$TAB$(basename "$2")$TAB$3$TAB${4:0:7}$TAB$5" >> "$NOTES"
}

# post-commit hook: note every commit made in another repo that has a GitHub remote.
cmd_note_commit() {
  local repo
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
  [ "$(cd "$repo" && pwd)" = "$ROOT" ] && exit 0
  git remote -v 2>/dev/null | grep -qE "$URL_PATTERN" || exit 0
  add_note commit "$repo" "$(git symbolic-ref -q --short HEAD || echo detached)" \
    "$(git rev-parse HEAD)" "$(git log -1 --format=%s)"
  exit 0
}

# Markdown list of every waiting commit, grouped by repo. $1 = 1 to include this repo.
queue_report() (
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
  rows_for() {
    git -C "$1" log --reverse --date=short --format='%h%x09%ad%x09%s' "$2" --not --remotes="$3" 2>/dev/null \
      | awk -F'\t' '{ gsub(/[|]/, "\\&#124;", $3); print "| `" $1 "` | " $2 " | " $3 " |" }'
  }
  section() {   # TITLE REPO REF REMOTE [pattern of rows to leave out]
    local rows
    rows="$(rows_for "$2" "$3" "$4" | { if [ -n "${5:-}" ]; then grep -vE "$5"; else cat; fi; })"
    [ -n "$rows" ] || return 0
    echo "## $1"; echo
    echo "$(echo "$rows" | grep -c .) commit(s) waiting"; echo
    echo "| Commit | Written on | Message |"; echo "|---|---|---|"
    echo "$rows"; echo
  }
  body="$(
    if [ "$1" = 1 ]; then section "$(basename "$ROOT") (this repo)" "$ROOT" HEAD origin '\| (journal|notes): '; fi
    while IFS="$TAB" read -r repo remote lref rref; do
      [ -n "$repo" ] || continue
      section "$(basename "$repo") (branch ${lref#refs/heads/})" "$repo" "$lref" "$remote"
    done < "$QUEUE"
  )"
  echo "# Commit waitlist"; echo
  echo "Commits held back until the next scheduled day. Up to $DAILY_TARGET go out per day, oldest first."; echo
  echo "- Last updated: $(date '+%F %H:%M')"
  echo "- Next release day: $(next_pdate)"
  echo "- Waiting: $(echo "$body" | grep -c '^| `') commit(s)"
  echo "- Notes waiting: $(grep -c . "$NOTES") (each becomes its own commit in the notes file)"; echo
  if [ -n "$body" ]; then echo "$body"; else echo "Nothing is waiting."; fi
)
write_queue_md() { queue_report "$1" > "$ROOT/QUEUE.md"; }

# ---------------------------------------------------------------- pre-push hook
cmd_hook() {
  local remote="${1:-}" url="${2:-}"
  if [ -n "${WAITLIST_RELEASE:-}" ] || [ -n "${WAITLIST_BYPASS:-}" ]; then exit 0; fi
  echo "$url" | grep -qE "$URL_PATTERN" || exit 0

  local repo queued=0 lref lsha rref rsha entry
  repo="$(git rev-parse --show-toplevel)"
  if [ "$(cd "$repo" && pwd)" = "$ROOT" ]; then
    echo "waitlist: push held. This repo is pushed automatically on scheduled days, with its commits counted toward that day." >&2
    exit 1
  fi
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
    add_note push "$repo" "${lref#refs/heads/}" "$lsha" \
      "push of $(git rev-list --count "$lsha" --not --remotes="$remote" 2>/dev/null || echo '?') commit(s) held"
    queued=1
  done
  [ "$queued" = 1 ] || exit 0
  write_queue_md 1

  local next; next="$(next_pdate)"
  {
    echo ""
    echo "waitlist: push held. $repo is on the waitlist."
    if [ -z "$next" ]; then
      echo "waitlist: no scheduled dates remain - push with WAITLIST_BYPASS=1 or uninstall."
    else
      echo "waitlist: next release day is $next (up to $DAILY_TARGET commits go out per day, oldest first)."
    fi
    echo "waitlist: to push right now anyway:  WAITLIST_BYPASS=1 git push"
    echo ""
  } >&2
  exit 1
}

# ------------------------------------------------------------- release one ref
# release_entry REPO REMOTE LOCALREF REMOTEREF STAMP LIMIT [KEEP_RE]
# Pushes the oldest commits the remote does not have yet, re-dating them to
# STAMP. LIMIT is the most commits to re-date and push (-1 = no limit). Commits
# whose subject matches KEEP_RE keep their date and do not count toward LIMIT.
# Anything after the cut-off stays local with its date untouched.
# Sets RELEASED to the number of re-dated commits pushed.
# Returns 0 when nothing is left to push, non-zero when the entry must stay queued.
release_entry() {
  local repo="$1" remote="$2" lref="$3" rref="$4" stamp="$5" limit="$6" keepre="${7:-}"
  RELEASED=0
  local gd; gd="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || {
    log "drop  $repo (not a git repo any more)"; return 0; }
  local tip; tip="$(git -C "$repo" rev-parse -q --verify "$lref")" || {
    log "drop  $repo $lref (branch no longer exists)"; return 0; }
  if [ -e "$gd/rebase-merge" ] || [ -e "$gd/rebase-apply" ] || [ -e "$gd/MERGE_HEAD" ] || [ -e "$gd/CHERRY_PICK_HEAD" ]; then
    log "wait  $repo has a rebase or merge in progress; left on the waitlist"; return 1
  fi

  local -a list=()
  mapfile -t list < <(git -C "$repo" rev-list --reverse --topo-order "$tip" --not --remotes="$remote")
  local total="${#list[@]}" k=-1 counted=0 keep
  [ "$total" -gt 0 ] || return 0

  local -A map=()
  local c p new tree ad cd msg i=0
  local -a parents pargs
  msg="$(mktemp)"
  for c in "${list[@]}"; do
    tree="$(git -C "$repo" rev-parse "$c^{tree}")"
    read -r -a parents <<< "$(git -C "$repo" rev-list --parents -n 1 "$c" | cut -s -d' ' -f2-)"
    pargs=()
    for p in "${parents[@]}"; do pargs+=(-p "${map[$p]:-$p}"); done
    keep=0
    if [ -n "$keepre" ] && git -C "$repo" log -1 --format=%s "$c" | grep -qE "$keepre"; then keep=1; fi
    if [ "$k" -lt 0 ] && [ "$keep" = 0 ]; then
      if [ "$limit" -ge 0 ] && [ "$counted" -ge "$limit" ]; then k="$i"; else counted=$(( counted + 1 )); fi
    fi
    if [ "$k" -ge 0 ] || [ "$keep" = 1 ]; then
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
  [ "$k" -ge 0 ] || k="$total"
  [ "$k" -gt 0 ] || return 0          # nothing here may go out yet

  local newtip="${map[$tip]:-$tip}"
  if [ "$newtip" != "$tip" ]; then
    git -C "$repo" update-ref -m "waitlist: re-date for release" "$lref" "$newtip" "$tip" || {
      log "FAIL  $repo: could not move $lref"; return 1; }
  fi
  local pushsha="${map[${list[$((k - 1))]}]}"
  if ! WAITLIST_RELEASE=1 git -C "$repo" push -q "$remote" "$pushsha:$rref" >>"$LOG" 2>&1; then
    # Undo the re-dating so the commits get the right day when they do go out.
    [ "$newtip" = "$tip" ] || git -C "$repo" update-ref -m "waitlist: push failed, undo re-date" "$lref" "$tip" "$newtip"
    log "FAIL  push $repo ${lref#refs/heads/} -> $remote (kept on the waitlist, see log above)"
    return 1
  fi
  RELEASED="$counted"
  log "push $repo ${lref#refs/heads/} -> $remote ($k of $total commit(s))"
  [ "$k" -eq "$total" ]
}

# ------------------------------------------------------------------------- run
cmd_run() {
  local d i n stamp budget

  # Only one run at a time (the scheduled task and a manual run could overlap).
  local lock="$STATE/run.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
    else
      echo "waitlist: another run is in progress" >&2; return 0
    fi
  fi
  trap 'rmdir "$STATE/run.lock" 2>/dev/null' EXIT

  # 1. On a scheduled day, release waiting commits (oldest first) up to the daily target.
  if is_pdate "$TODAY"; then
    stamp="$(stamp_for "$TODAY")"
    local keep snap repo remote lref rref
    keep="$(mktemp)"; snap="$(mktemp)"
    cp "$QUEUE" "$snap"
    while IFS="$TAB" read -r repo remote lref rref; do
      [ -n "$repo" ] || continue
      # Keep 1 slot for the journal commit that carries QUEUE.md, plus room for
      # this repo's own waiting edits if they are going out today as well.
      budget=$(( DAILY_TARGET - 1 - $(used_on "$TODAY") ))
      grep -qx "$TODAY" "$DONE" || budget=$(( budget - $(root_extra) ))
      if [ "$budget" -le 0 ]; then
        echo "$repo$TAB$remote$TAB$lref$TAB$rref" >> "$keep"; continue
      fi
      release_entry "$repo" "$remote" "$lref" "$rref" "$stamp" "$budget" \
        || echo "$repo$TAB$remote$TAB$lref$TAB$rref" >> "$keep"
      add_used "$TODAY" "$RELEASED"
    done < "$snap"
    # Keep anything that was queued by a push while this loop was running.
    grep -vxFf "$snap" "$QUEUE" >> "$keep"
    mv "$keep" "$QUEUE"; rm -f "$snap"
  fi

  # Refresh QUEUE.md. Leave this repo out when it is about to be pushed anyway.
  local self=1
  for d in $(dates); do
    [[ "$d" > "$TODAY" ]] && break
    grep -qx "$d" "$DONE" || self=0
  done
  write_queue_md "$self"

  # 2. Fill each scheduled day up to the target. A day missed because the PC
  #    was off is back-filled with that day's date.
  local branch extra avail take
  branch="$(git -C "$ROOT" symbolic-ref -q HEAD || true)"
  if [ -z "$branch" ] || ! git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
    log "WARN  $ROOT must be on a branch with an 'origin' remote - nothing written"
    return 0
  fi
  for d in $(dates); do
    [[ "$d" > "$TODAY" ]] && break
    grep -qx "$d" "$DONE" && continue
    avail=$(( DAILY_TARGET - $(used_on "$d") ))
    [ "$avail" -gt 0 ] || avail=0

    # 2a. Edits to this tool itself go out first, oldest first, within the day's limit.
    extra="$(root_extra)"
    if [ "$extra" -gt 0 ] && [ "$avail" -gt 0 ]; then
      take="$extra"; [ "$take" -le "$avail" ] || take="$avail"
      release_entry "$ROOT" origin "$branch" "$branch" "$(stamp_for "$d")" "$take" "$SCHED_RE"
      if [ "$RELEASED" -eq 0 ]; then
        log "WARN  could not push this repo; $d will be filled on the next run"; break
      fi
      add_used "$d" "$RELEASED"; avail=$(( avail - RELEASED ))
    fi
    if [ "$(root_extra)" -gt 0 ]; then
      # More edits are still waiting, so the day is full and nothing can go on top yet.
      [ "$avail" -eq 0 ] || break
      echo "$d" >> "$DONE"
      log "filled $d with this repo's own waiting commits ($(used_on "$d") total that day)"
      continue
    fi

    # 2b. Notes, then journal filler, for whatever is left of the day.
    n="$avail"
    mkdir -p "$ROOT/journal"
    local nwhen nkind nrepo nbranch nsha ntext file msg popnote notes_done=0
    for i in $(seq 1 "$n"); do
      if [ "$d" = "$REAL_TODAY" ]; then stamp="$(date '+%F %T')"
      else stamp="$d 12:$(printf '%02d' "$i"):00"; fi
      if [ -s "$NOTES" ]; then
        # A waiting note (one per commit or held push in another repo) gets its own commit.
        IFS="$TAB" read -r nwhen nkind nrepo nbranch nsha ntext < "$NOTES"
        file="notes"
        # Make sure the existing file ends with a newline before appending.
        if [ -s "$ROOT/$file" ] && [ -n "$(tail -c 1 "$ROOT/$file")" ]; then echo >> "$ROOT/$file"; fi
        if [ "$nkind" = commit ]; then
          echo "$nwhen  $nrepo ($nbranch): committed $nsha - $ntext" >> "$ROOT/$file"
        else
          echo "$nwhen  $nrepo ($nbranch): $ntext (up to $nsha)" >> "$ROOT/$file"
        fi
        msg="notes: $nrepo: $nkind $nsha"
        popnote=1
      else
        popnote=0
        file="journal/$d.md"
        [ -f "$ROOT/$file" ] || echo "# $d" > "$ROOT/$file"
        echo "- entry $i of $n" >> "$ROOT/$file"
        msg="journal: $d ($i/$n)"
      fi
      git -C "$ROOT" add "$file" QUEUE.md 2>/dev/null
      GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" \
        git -C "$ROOT" commit -q -m "$msg" -- "$file" QUEUE.md || {
          log "FAIL  commit for $d ($msg)"; return 1; }
      if [ "$popnote" = 1 ]; then sed -i 1d "$NOTES"; notes_done=$(( notes_done + 1 )); fi
    done
    add_used "$d" "$n"
    echo "$d" >> "$DONE"
    echo "$d" > "$STATE/push-pending"
    log "wrote $notes_done note + $(( n - notes_done )) journal commit(s) for $d ($(used_on "$d") total that day)"
  done

  # 3. Push this repo, but only when a scheduled day was just filled (or an
  #    earlier attempt failed), so nothing lands outside the schedule.
  if [ -f "$STATE/push-pending" ]; then
    # Limit 0: only the scheduler's own commits go; a tool edit on top waits its turn.
    release_entry "$ROOT" origin "$branch" "$branch" "$(stamp_for "$(cat "$STATE/push-pending")")" 0 "$SCHED_RE"
    [ -z "$(git -C "$ROOT" log --format=%s "$branch" --not --remotes=origin | grep -E "$SCHED_RE")" ] \
      && rm -f "$STATE/push-pending"
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
  echo "This repo: $(git -C "$ROOT" rev-list --count HEAD --not --remotes=origin 2>/dev/null || echo '?') commit(s) waiting (go out on scheduled days, within the daily limit)"
  echo "Notes waiting: $(grep -c . "$NOTES")"
  echo "Other repos on the waitlist: $(grep -c . "$QUEUE")"
  local repo remote lref rref
  while IFS="$TAB" read -r repo remote lref rref; do
    [ -n "$repo" ] || continue
    echo "  $repo [${lref#refs/heads/} -> $remote]  $(git -C "$repo" rev-list --count "$lref" --not --remotes="$remote" 2>/dev/null || echo '?') commit(s) waiting"
  done < "$QUEUE"
}

case "${1:-}" in
  run) cmd_run ;;
  status) cmd_status ;;
  list) queue_report 1 ;;
  hook) shift; cmd_hook "$@" ;;
  note-commit) cmd_note_commit ;;
  *) echo "usage: waitlist.sh run | status | list" >&2; exit 2 ;;
esac
