#!/bin/bash
# ci.sh — drive GitHub Actions without touching HEAD or the real index.
#
#   ./scripts/ci.sh run <suite>
#       Snapshot the working tree (tracked + untracked, not ignored) into a
#       commit parented on HEAD, push refs/heads/ci/<suite>-<tree12> with
#       message "ci: suite=<suite>", and wait for that run. A run that already
#       exists for the branch+sha is reused.
#   ./scripts/ci.sh verify <suite>
#       Same tree. Exit 0 if ci/<suite>-<tree12> or ci/all-<tree12> already
#       succeeded. Wait for an in-progress covering run, or start one. Never
#       wait longer than 14 minutes; then exit non-zero with
#       "CI still running: <url>".
#   ./scripts/ci.sh prune
#       Delete remote ci/* branches whose tip commit is older than 3 days.
#
# Suites: all | unit | ui | ui1 | ui2 | ui3 | ui4 | build
# The owner's Mac must not run xcodebuild or simulators; this script only
# pushes and polls. swift test of FinanceCore locally is fine.
set -euo pipefail

REPO="sfgsfgdsfds/am-finance"
URL="https://github.com/${REPO}.git"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERIFY_BUDGET_SECONDS=$((14 * 60))
RUN_BUDGET_SECONDS=$((110 * 60))
POLL_SECONDS=20

# Sleep one poll interval, but never past the caller's deadline.
sleep_until() { # $1 deadline epoch
  local deadline="$1" now remain
  now="$(date +%s)"
  remain=$((deadline - now))
  if [ "$remain" -le 0 ]; then
    return 0
  fi
  if [ "$remain" -gt "$POLL_SECONDS" ]; then
    sleep "$POLL_SECONDS"
  else
    sleep "$remain"
  fi
}

usage() {
  echo "usage: ci.sh run <all|unit|ui|ui1|ui2|ui3|ui4|build>" >&2
  echo "       ci.sh verify <all|unit|ui|ui1|ui2|ui3|ui4|build>" >&2
  echo "       ci.sh prune" >&2
  exit 2
}

valid_suite() {
  case "$1" in
    all|unit|ui|ui1|ui2|ui3|ui4|build) return 0 ;;
    *) return 1 ;;
  esac
}

# Private repo; the global credential helper points at a missing Homebrew gh.
# Override it for this invocation only — do not change git config.
git_auth() {
  git \
    -c credential.helper= \
    -c credential.https://github.com.helper= \
    -c "credential.helper=!$(command -v gh) auth git-credential" \
    "$@"
}

# Retry transient GitHub API blips so a long wait is not abandoned after one 502.
gh_repo() {
  local attempt=1 status
  while true; do
    if gh -R "$REPO" "$@"; then
      return 0
    fi
    status=$?
    if [ "$attempt" -ge 5 ]; then
      return "$status"
    fi
    echo "ci: gh failed (${status}), retry ${attempt}" >&2
    attempt=$((attempt + 1))
    sleep 10
  done
}

# Tree of the current working tree. Does not touch HEAD or the real index.
snapshot_tree() {
  local index tree
  index="$(mktemp "${TMPDIR:-/tmp}/amfinance-ci-index.XXXXXX")"
  tree="$(
    export GIT_INDEX_FILE="$index"
    git read-tree HEAD
    git add -A
    git write-tree
  )" || {
    rm -f "$index"
    echo "ci: failed to snapshot the working tree" >&2
    return 1
  }
  rm -f "$index"
  if ! git ls-tree -r --name-only "$tree" | grep -qx '.github/workflows/ci.yml'; then
    echo "ci: snapshot is missing .github/workflows/ci.yml" >&2
    return 1
  fi
  printf '%s\n' "$tree"
}

tree12_of() {
  printf '%.12s\n' "$1"
}

branch_for() { # $1 suite, $2 full tree sha
  printf 'ci/%s-%s\n' "$1" "$(tree12_of "$2")"
}

remote_tip() { # $1 branch (ci/...) — prints sha or empty
  git_auth ls-remote "$URL" "refs/heads/$1" | awk '{print $1; exit}'
}

# Ensure the remote branch exists and points at a commit with this tree.
# Prints the commit sha. Reuses the tip when the branch is already there.
ensure_commit() { # $1 suite, $2 tree
  local suite="$1" tree="$2" branch tip parent sha fetched
  branch="$(branch_for "$suite" "$tree")"
  tip="$(remote_tip "$branch" || true)"
  if [ -n "$tip" ]; then
    git_auth fetch --no-tags "$URL" "refs/heads/${branch}" >/dev/null
    fetched="$(git rev-parse 'FETCH_HEAD^{tree}')"
    if [ "$fetched" != "$tree" ]; then
      echo "ci: $branch points at tree $fetched, wanted $tree" >&2
      return 1
    fi
    printf '%s\n' "$tip"
    return 0
  fi
  parent="$(git rev-parse HEAD)"
  sha="$(git commit-tree "$tree" -p "$parent" -m "ci: suite=${suite}")" || return 1
  # commit-tree does not move HEAD. Push only this ref.
  if ! git_auth push "$URL" "${sha}:refs/heads/${branch}"; then
    tip="$(remote_tip "$branch" || true)"
    if [ -z "$tip" ]; then
      echo "ci: push of $branch failed" >&2
      return 1
    fi
    printf '%s\n' "$tip"
    return 0
  fi
  printf '%s\n' "$sha"
}

# One line: none | success <id> <url> | running <id> <url> <status> | done <id> <url> <conclusion>
classify_runs() { # $1 branch, $2 sha
  local branch="$1" sha="$2"
  gh_repo run list --commit "$sha" --branch "$branch" --workflow ci.yml --limit 20 \
    --json databaseId,status,conclusion,url,createdAt \
    --jq '
      if length == 0 then
        "none"
      elif any(.[]; .conclusion == "success") then
        ([.[] | select(.conclusion == "success")] | .[0]) | "success \(.databaseId) \(.url)"
      elif any(.[]; .status != "completed") then
        ([.[] | select(.status != "completed")] | .[0]) | "running \(.databaseId) \(.url) \(.status)"
      else
        .[0] | "done \(.databaseId) \(.url) \(.conclusion // "unknown")"
      end
    '
}

print_job_summary() { # $1 run id
  local id="$1"
  gh_repo run view "$id" --json jobs \
    --jq '.jobs[] | "\(.name)\t\(.conclusion // .status)\t\(.startedAt // "")\t\(.completedAt // "")"' \
    | python3 -c '
import sys
from datetime import datetime
total = 0.0
mac = 0.0
print("ci: jobs")
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    name, conclusion, started, completed = (line.split("\t") + ["", "", "", ""])[:4]
    secs = None
    if started and completed:
        fmt = "%Y-%m-%dT%H:%M:%SZ"
        try:
            a = datetime.strptime(started, fmt)
            b = datetime.strptime(completed, fmt)
            secs = (b - a).total_seconds()
        except ValueError:
            secs = None
    if secs is None:
        shown = "-"
    else:
        shown = "%dm%02ds" % (int(secs) // 60, int(secs) % 60)
        total += secs
        if name != "prepare":
            mac += secs
    print("  %-22s %-12s %s" % (name, conclusion, shown))
print("ci: macOS job time (excludes prepare): %.1f min" % (mac / 60.0))
print("ci: all job time: %.1f min" % (total / 60.0))
'
}

print_failed_logs() { # $1 run id
  local id="$1"
  echo "ci: failing log tail:" >&2
  gh_repo run view "$id" --log-failed 2>/dev/null | tail -n 200 >&2 || true
}

wait_run() { # $1 run id, $2 url, $3 deadline epoch (0 = no deadline)
  local id="$1" url="$2" deadline="$3" now line status conclusion
  while true; do
    now="$(date +%s)"
    if [ "$deadline" -ne 0 ] && [ "$now" -ge "$deadline" ]; then
      echo "CI still running: ${url}"
      return 1
    fi
    line="$(gh_repo run view "$id" --json status,conclusion,url --jq '"\(.status) \(.conclusion // "-") \(.url)"')"
    status="${line%% *}"
    conclusion="${line#* }"
    conclusion="${conclusion%% *}"
    if [ "$status" = "completed" ]; then
      print_job_summary "$id" || true
      if [ "$conclusion" = "success" ]; then
        echo "ci: green ${url}"
        return 0
      fi
      echo "ci: ${conclusion} ${url}" >&2
      print_failed_logs "$id"
      return 1
    fi
    echo "ci: ${status} ${url}"
    sleep "$POLL_SECONDS"
  done
}

# Classify one remote branch: missing | pending | success id url | running id url | done id url conclusion
classify_branch() { # $1 branch
  local branch="$1" sha rest
  sha="$(remote_tip "$branch" || true)"
  if [ -z "$sha" ]; then
    printf 'missing\n'
    return 0
  fi
  rest="$(classify_runs "$branch" "$sha")" || return 1
  if [ "$rest" = "none" ]; then
    printf 'pending\n'
  else
    printf '%s\n' "$rest"
  fi
}

# Covering runs for verify: the suite branch, plus ci/all when that is a
# different branch. A green ci/all covers every suite. A failed ci/all does
# not — the suite branch is started on its own. pending means the suite
# branch exists but its workflow run has not appeared yet.
covering_state() { # $1 suite, $2 tree
  local suite="$1" tree="$2"
  local suite_branch suite_state all_state=""
  local success="" running=""
  suite_branch="$(branch_for "$suite" "$tree")"
  suite_state="$(classify_branch "$suite_branch")" || return 1
  if [ "$suite" != "all" ]; then
    all_state="$(classify_branch "$(branch_for all "$tree")")" || return 1
  fi

  case "$suite_state" in
    success\ *) success="$suite_state" ;;
  esac
  case "$all_state" in
    success\ *) [ -n "$success" ] || success="$all_state" ;;
  esac
  if [ -n "$success" ]; then
    printf '%s\n' "$success"
    return 0
  fi

  case "$suite_state" in
    running\ *) running="$suite_state" ;;
  esac
  case "$all_state" in
    running\ *) [ -n "$running" ] || running="$all_state" ;;
  esac
  if [ -n "$running" ]; then
    printf '%s\n' "$running"
    return 0
  fi

  case "$suite_state" in
    pending)
      printf 'pending\n'
      return 0
      ;;
    done\ *)
      # Own run finished without success.
      printf 'failed %s %s\n' \
        "$(printf '%s\n' "$suite_state" | awk '{print $2}')" \
        "$(printf '%s\n' "$suite_state" | awk '{print $3}')"
      return 0
      ;;
  esac
  # Suite branch does not exist. A failed ci/all is not a result for this suite.
  printf 'missing\n'
}

cmd_run() {
  local suite="$1" tree branch sha state kind id url deadline
  tree="$(snapshot_tree)"
  branch="$(branch_for "$suite" "$tree")"
  echo "ci: suite=${suite} tree=$(tree12_of "$tree") branch=${branch}"
  sha="$(ensure_commit "$suite" "$tree")"
  echo "ci: commit ${sha}"

  deadline=$(( $(date +%s) + RUN_BUDGET_SECONDS ))
  while true; do
    # `run` watches only this suite's branch. A green ci/all does not
    # substitute — the caller asked to execute this suite.
    sha="$(remote_tip "$branch" || true)"
    if [ -z "$sha" ]; then
      echo "ci: $branch disappeared" >&2
      return 1
    fi
    state="$(classify_runs "$branch" "$sha")" || return 1
    kind="${state%% *}"
    case "$kind" in
      success|running|done)
        id="$(printf '%s\n' "$state" | awk '{print $2}')"
        url="$(printf '%s\n' "$state" | awk '{print $3}')"
        if [ "$kind" = "success" ] && [ "$(gh_repo run view "$id" --json status --jq .status)" = "completed" ]; then
          print_job_summary "$id" || true
          echo "ci: green ${url}"
          return 0
        fi
        if [ "$kind" = "done" ]; then
          print_job_summary "$id" || true
          echo "ci: $(printf '%s\n' "$state" | awk '{print $4}') ${url}" >&2
          print_failed_logs "$id"
          return 1
        fi
        wait_run "$id" "$url" "$deadline"
        return $?
        ;;
      none)
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "ci: no workflow run appeared for ${branch}" >&2
          echo "CI still running: https://github.com/${REPO}/actions?query=branch%3A${branch}"
          return 1
        fi
        echo "ci: waiting for a run on ${branch}"
        sleep "$POLL_SECONDS"
        ;;
      *)
        echo "ci: unexpected classify: $state" >&2
        return 1
        ;;
    esac
  done
}

cmd_verify() {
  local suite="$1" tree branch sha state kind id url deadline now
  local started
  started="$(date +%s)"
  deadline=$(( started + VERIFY_BUDGET_SECONDS ))
  tree="$(snapshot_tree)"
  branch="$(branch_for "$suite" "$tree")"
  echo "ci: verify suite=${suite} tree=$(tree12_of "$tree") branch=${branch}" >&2

  while true; do
    now="$(date +%s)"
    state="$(covering_state "$suite" "$tree")"
    kind="${state%% *}"
    case "$kind" in
      success)
        id="$(printf '%s\n' "$state" | awk '{print $2}')"
        url="$(printf '%s\n' "$state" | awk '{print $3}')"
        echo "ci: green ${url}"
        return 0
        ;;
      running)
        id="$(printf '%s\n' "$state" | awk '{print $2}')"
        url="$(printf '%s\n' "$state" | awk '{print $3}')"
        if [ "$now" -ge "$deadline" ]; then
          echo "CI still running: ${url}"
          return 1
        fi
        echo "ci: running ${url}" >&2
        sleep_until "$deadline"
        ;;
      failed)
        id="$(printf '%s\n' "$state" | awk '{print $2}')"
        url="$(printf '%s\n' "$state" | awk '{print $3}')"
        # A failed ci/all does not prove a narrower suite failed. Start the
        # suite branch when its own run does not exist yet.
        sha="$(remote_tip "$branch" || true)"
        if [ -z "$sha" ]; then
          echo "ci: covering run failed; starting ${branch}" >&2
          sha="$(ensure_commit "$suite" "$tree")"
          echo "ci: commit ${sha}" >&2
          sleep_until "$deadline"
          continue
        fi
        echo "ci: failed ${url}" >&2
        print_failed_logs "$id"
        return 1
        ;;
      pending)
        if [ "$now" -ge "$deadline" ]; then
          echo "CI still running: https://github.com/${REPO}/actions?query=branch%3A${branch}"
          return 1
        fi
        echo "ci: waiting for a run on ${branch}" >&2
        sleep_until "$deadline"
        ;;
      missing)
        if [ "$now" -ge "$deadline" ]; then
          echo "CI still running: https://github.com/${REPO}/actions?query=branch%3A${branch}"
          return 1
        fi
        echo "ci: starting ${branch}" >&2
        sha="$(ensure_commit "$suite" "$tree")"
        echo "ci: commit ${sha}" >&2
        sleep_until "$deadline"
        ;;
      *)
        echo "ci: unexpected state: $state" >&2
        return 1
        ;;
    esac
  done
}

cmd_prune() {
  local ref sha type iso old short deleted=0
  while IFS="$(printf '\t')" read -r ref sha type; do
    [ -n "${ref:-}" ] || continue
    case "$ref" in
      refs/heads/ci/*) ;;
      *) continue ;;
    esac
    if [ "$type" != "commit" ]; then
      echo "ci: skip $ref (object type $type)" >&2
      continue
    fi
    iso="$(gh_repo api "repos/${REPO}/commits/${sha}" --jq .commit.committer.date)"
    old="$(python3 -c '
import sys, datetime
iso = sys.argv[1].replace("Z", "+00:00")
dt = datetime.datetime.fromisoformat(iso)
cut = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=3)
print("1" if dt < cut else "0")
' "$iso")"
    if [ "$old" != "1" ]; then
      continue
    fi
    short="${ref#refs/}"
    echo "ci: deleting ${ref#refs/heads/} (${iso})"
    gh_repo api -X DELETE "repos/${REPO}/git/refs/${short}" >/dev/null
    deleted=$((deleted + 1))
  done < <(gh_repo api --paginate "repos/${REPO}/git/matching-refs/heads/ci/" \
    --jq '.[] | [.ref, .object.sha, .object.type] | @tsv')
  if [ "$deleted" -eq 0 ]; then
    echo "ci: no ci/* branches older than 3 days"
  else
    echo "ci: deleted ${deleted} branch(es)"
  fi
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    run|verify)
      [ $# -eq 2 ] || usage
      valid_suite "$2" || usage
      if [ "$cmd" = "run" ]; then
        cmd_run "$2"
      else
        cmd_verify "$2"
      fi
      ;;
    prune)
      [ $# -eq 1 ] || usage
      cmd_prune
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
