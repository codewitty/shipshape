#!/usr/bin/env bash
# prloop.sh - GitHub PR review-thread helper for the pr-review-loop skill.
#
# Subcommands:
#   status    Print a one-object JSON summary of the PR and its review state.
#   threads   Print actionable review threads as JSON (--human, --bots, --all).
#   spec      Print the PR body plus any linked issues, as JSON.
#   reply     Post an inline reply to one review thread (stamps the agent marker).
#   resolve   Mark one review thread resolved.
#   comment   Post a PR-level comment, stamped as an agent post.
#   ask-signoff  Ask on the PR whether an ambiguous comment meant sign-off (once per head).
#   request-review  Ask the review bot for a pass on the current head (once per head; --force repeats).
#   wait      Block until something happens, with escalating backoff. Run in background.
#
# Global options: --repo owner/name  --pr N   (both default to the current checkout)
#
# Environment overrides:
#   GH              path to the gh binary
#   PRLOOP_BOTS     space-separated extra bot logins (any *[bot] login is automatic)
#   PRLOOP_STOP_RE  regex for "halt the loop", matched per line
#   PRLOOP_SIGNOFF_RE regex for "I approve this", matched per line
#   PRLOOP_DELAYS   space-separated backoff seconds for `wait`
#   PRLOOP_REVIEW_TRIGGER  comment that summons the review bot (default "@codex review");
#                          "none" means the repo has no review bot and request-review does nothing
#   PRLOOP_REVIEW_BOT      login of the bot that answers it (default chatgpt-codex-connector)
#   PRLOOP_REVIEWED_RE     regex for the bot's "I read commit X" line (default "Reviewed commit")
#   PRLOOP_BOT_CLEAN_RE    regex for the bot's clean verdict (default "Didn't find any major issues")
#   PRLOOP_BOT_SIGNOFF     0 to stop a clean bot pass on the head from counting as sign-off (default 1)
set -euo pipefail

# ---------------------------------------------------------------- prerequisites
GH="${GH:-}"
if [[ -z "$GH" ]]; then
  GH="$(command -v gh 2>/dev/null || true)"
  if [[ -z "$GH" ]]; then
    for c in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
      [[ -x "$c" ]] && { GH="$c"; break; }
    done
  fi
fi
[[ -n "$GH" && -x "$GH" ]] || { echo "prloop: gh CLI not found. Install it or export GH=/path/to/gh" >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "prloop: jq not found." >&2; exit 127; }

# ---------------------------------------------------------------- arg parsing
CMD="${1:-}"; shift || true
REPO=""; PR=""; THREAD=""; BODY=""; BODY_FILE=""; SCOPE="actionable"; FORCE=0
MAX_WAIT=0   # 0 means never time out; this is a service, not a one-shot

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --pr)        PR="$2"; shift 2 ;;
    --thread)    THREAD="$2"; shift 2 ;;
    --body)      BODY="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --all)       SCOPE="all"; shift ;;
    --human)     SCOPE="human"; shift ;;
    --bots)      SCOPE="bots"; shift ;;
    --max-wait)  MAX_WAIT="$2"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   CMD="help"; shift ;;
    *)           echo "prloop: unknown option $1" >&2; exit 2 ;;
  esac
done

# Print the comment header, stopping at the first non-comment line, so the help
# text cannot drift out of sync with the header as subcommands are added.
usage() { sed -n '2,/^[^#]/p' "$0" | sed 's/^# \{0,1\}//; $d'; }
case "$CMD" in ""|help|-h|--help) usage; exit 0 ;; esac

# ---------------------------------------------------------------- context
[[ -n "$REPO" ]] || REPO="$("$GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
[[ -n "$REPO" ]] || { echo "prloop: could not determine repo. Pass --repo owner/name." >&2; exit 2; }
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

[[ -n "$PR" ]] || PR="$("$GH" pr view --json number --jq .number 2>/dev/null || true)"
[[ -n "$PR" ]] || { echo "prloop: could not determine PR number. Pass --pr N." >&2; exit 2; }

# Invisible stamp appended to every reply this script posts. The loop uses the
# presence of this marker, NOT the comment author, to tell its own replies apart
# from a reviewer's comments. Author identity is unreliable: on a solo PR the
# reviewer and the PR author are the same GitHub account, so "is this comment
# mine?" cannot be answered by login.
MARKER="${PRLOOP_MARKER:-<!-- prloop:agent-reply -->}"
# Stamped on the one comment the loop posts when a sign-off is ambiguous. Keyed
# to the head SHA so the question is asked once per commit and asks again if new
# code lands, and so it survives a restart without any local state.
QUERY_MARKER_PREFIX="${PRLOOP_QUERY_MARKER:-<!-- prloop:signoff-query head=}"
# The comment that summons the review bot, and the login that answers it. Every
# round ends by posting the trigger, stamped with the head it was asked for, so
# the bot re-reads the code it is about to be asked about and the loop never
# waits on a review that was never requested. Codex answers a clean pass with a
# PR comment naming the commit ("Reviewed commit: `<sha>`") and no threads, so
# `status` reports bot_reviewed_head from that and `wait` wakes on it.
REVIEW_TRIGGER="${PRLOOP_REVIEW_TRIGGER:-@codex review}"
REVIEW_BOT="${PRLOOP_REVIEW_BOT:-chatgpt-codex-connector}"
REVIEW_MARKER_PREFIX="${PRLOOP_REVIEW_MARKER:-<!-- prloop:review-request head=}"
# How the bot says which commit it finished reading. Codex: "Reviewed commit: `sha`".
REVIEWED_RE="${PRLOOP_REVIEWED_RE:-Reviewed commit}"
# How the bot says the pass found nothing. Codex posts a PR comment:
#   "Codex Review: Didn't find any major issues. ... Reviewed commit: `sha`"
# On a solo PR that is the only sign-off the loop can get, since GitHub will not
# let the author approve their own PR, so it counts as one unless disabled.
BOT_CLEAN_RE="${PRLOOP_BOT_CLEAN_RE:-Didn.t find any (major )?issues}"
BOT_SIGNOFF="${PRLOOP_BOT_SIGNOFF:-1}"

# Logins whose comments are bot review output. Any login ending in [bot] counts
# automatically; these are the common apps that do not use that suffix.
BOTS_RAW="${PRLOOP_BOTS:-coderabbitai chatgpt-codex-connector github-actions sonarcloud codecov sourcery-ai deepsource-autofix}"
BOTS_JSON="$(printf '%s\n' $BOTS_RAW | jq -R . | jq -sc .)"

# A review tool's PR-level marker, e.g.
#   <!-- adversarial-pr-review-loop base=<sha> head=<sha> blocking=2 -->
# The blocking= count is authoritative: it is the reviewer's own tally of what
# still blocks, for a named commit, so it cannot drift the way prose does.
BLOCKING_MARKER_RE="${PRLOOP_BLOCKING_MARKER_RE:-<!--[^>]*?blocking=([0-9]+)[^>]*?-->}"
# Severity tag at the head of a review comment: [P2 blocking], P1, 🟠 Major.
SEVERITY_RE="${PRLOOP_SEVERITY_RE:-(?<![A-Za-z0-9])P([0-5])(?![0-9])}"
LABEL_RE="${PRLOOP_LABEL_RE:-(?<![A-Za-z])(blocker|critical|major|minor|nit|trivial)(?![A-Za-z])}"

# An HTML comment a review tool leaves to declare sign-off, optionally carrying
# the commit it signed off on. Structured markers beat prose: they cannot be
# matched by accident, and a head= SHA lets us tell a live sign-off from one that
# a later push invalidated.
SIGNOFF_MARKER_RE="${PRLOOP_SIGNOFF_MARKER_RE:-<!--[^>]*?sign[ _-]?off}"
# Loose net, used only to surface a near miss so a sign-off is never lost silently.
SIGNOFF_HINT_RE="${PRLOOP_SIGNOFF_HINT_RE:-sign[ _-]?off|lgtm|approved|no blocking|0 blocking|zero blocking|ship ?it|good to merge}"

STOP_RE="${PRLOOP_STOP_RE:-^[[:space:]]*[\"'\`(]*(/?(stop|pause|halt|hold|freeze))[.!]*[\"'\`)]*[[:space:]]*$}"
SIGNOFF_RE="${PRLOOP_SIGNOFF_RE:-^[[:space:]]*[\"'\`(]*(/?(lgtm|approved|approve|ship ?it|looks good to me|sign[ -]?off|signed[ -]?off|good to merge))[.!]*[\"'\`)]*[[:space:]]*$}"

# ---------------------------------------------------------------- data fetch
GQL='
query($owner:String!, $name:String!, $pr:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$pr) {
      number title url state isDraft merged
      reviewDecision headRefName headRefOid baseRefName body
      author { login }
      closingIssuesReferences(first:10) { nodes { number title url body } }
      comments(last:40) { nodes { author { login } body createdAt url } }
      reviews(last:30) { nodes { author { login } state body submittedAt url } }
      reviewThreads(first:100) {
        nodes {
          id isResolved isOutdated path line startLine originalLine originalStartLine diffSide
          viewerCanReply viewerCanResolve
          comments(first:50) {
            nodes { databaseId url author { login } body createdAt diffHunk }
          }
        }
      }
    }
  }
}'

fetch() { "$GH" api graphql -f query="$GQL" -F owner="$OWNER" -F name="$NAME" -F pr="$PR"; }

# Shared jq preamble.
#
# actionable = unresolved AND the last comment is not one of our own replies.
# Detecting "our own reply" by marker rather than by author is what makes this
# work when the reviewer and the PR author are the same account. Replying marks
# a thread handled; the reviewer answering the reply makes it actionable again
# with no state to keep on disk.
#
# is_bot splits reviewer comments from automated review output so the loop can
# clear the human's threads before it spends a round on bot nits.
ANNOTATE='
def isbot($l): ($l | test("\\[bot\\]$")) or (($bots | index($l)) != null);
def mine: (.body // "") | contains($marker);
def lastc: (.comments.nodes | last);
def lines($re): (. // "") | split("\n") | any(test($re; "i"));
# Severity is read from the opening of the thread, where reviewers put it, not
# from the whole body: "not blocking" in a later paragraph must not reclassify a
# [P2 blocking] header. 400 chars covers every shape seen in practice.
def head400: (. // "") | .[0:400];
# $head is the current head SHA of the PR; .mh is the SHA a marker named,
# possibly abbreviated. Bind .mh before comparing. Inside an index or a function
# argument jq rebinds "." to the value being operated on, so a bare .mh there
# resolves against the wrong input and compares as false.
# Rank for ordering work. Reviewers mix scales, so P-numbers and word labels are
# folded onto one axis: a CodeRabbit "Major" sorts alongside a human P2.
def sevrank($s):
  if   $s == null then 5
  else ($s | ascii_downcase) as $x
  | if   $x == "p0" or $x == "blocker" or $x == "critical" then 0
    elif $x == "p1"                                        then 1
    elif $x == "p2" or $x == "major"                       then 2
    elif $x == "p3" or $x == "minor"                       then 3
    elif $x == "p4" or $x == "p5" or $x == "nit" or $x == "trivial" then 4
    else 5 end end;
def on_head($h): (.mh) as $m
  | if $m == null then null
    else ($h | ascii_downcase | startswith($m | ascii_downcase)) end;
def sev($b):
  ($b | head400) as $h
  | ($h | [scan($sevre; "i")] | flatten | map(select(type == "string")) | first) as $p
  | ($h | [scan($labre; "i")] | flatten | map(select(type == "string")) | first) as $l
  | if $p != null then "P" + $p
    elif $l != null then ($l | ascii_downcase | .[0:1] | ascii_upcase) + ($l | ascii_downcase | .[1:])
    else null end;
def blk($b):
  ($b | head400) as $h
  | if   ($h | test("non[ -]?blocking|(?<![A-Za-z])(nit|trivial)(?![A-Za-z])"; "i")) then false
    elif ($h | test("(?<![A-Za-z])(blocking|blocker)(?![A-Za-z])"; "i"))            then true
    else null end;
.data.repository.pullRequest
| .reviewThreads.nodes |= map(
    . + {
      last_author: ((lastc.author.login) // "unknown"),
      comment_count: (.comments.nodes | length),
      is_bot: ([.comments.nodes[] | select((mine) | not) | (.author.login // "unknown")]
               | map(isbot(.)) | (length > 0 and all)),
      actionable: ((.isResolved | not) and ((lastc | mine) | not)),
      severity: sev([.comments.nodes[] | select((mine) | not) | .body] | first // ""),
      blocking: blk([.comments.nodes[] | select((mine) | not) | .body] | first // "")
    })
'

# ---------------------------------------------------------------- subcommands
case "$CMD" in

status)
  fetch | jq --arg marker "$MARKER" --argjson bots "$BOTS_JSON" --arg sevre "$SEVERITY_RE" --arg labre "$LABEL_RE" \
             --arg stop_re "$STOP_RE" --arg signoff_re "$SIGNOFF_RE" \
             --arg sm_re "$SIGNOFF_MARKER_RE" --arg hint_re "$SIGNOFF_HINT_RE" \
             --arg blk_re "$BLOCKING_MARKER_RE" --arg qmark "$QUERY_MARKER_PREFIX" \
             --arg rmark "$REVIEW_MARKER_PREFIX" --arg rbot "$REVIEW_BOT" --arg reviewed_re "$REVIEWED_RE" \
             --arg clean_re "$BOT_CLEAN_RE" --argjson bot_signoff "$([[ "$BOT_SIGNOFF" == "0" ]] && echo false || echo true)" \
             "$ANNOTATE"'
    | . as $pr
    | ($pr.headRefOid // "") as $head
    | [ (.comments.nodes[] | {a: (.author.login // "unknown"), b: .body}),
        (.reviews.nodes[]  | {a: (.author.login // "unknown"), b: (.body // "")}),
        (.reviewThreads.nodes[].comments.nodes[]
                           | {a: (.author.login // "unknown"), b: .body}) ]
      | map(select((.b | contains($marker)) | not))
      | map(select(isbot(.a) | not))
      | map(. + {
          mk:   (.b | test($sm_re; "i")),
          mh:   (.b | [scan("<!--[^>]*?head=([0-9a-fA-F]{7,40})"; "i")]
                    | flatten | map(select(type == "string")) | first),
          ph:   (.b | lines($signoff_re)),
          hint: (.b | test($hint_re; "i"))
        })
      | map(. + { on_head: on_head($head) })
      | map(. + { counts: (.ph or (.mk and (.on_head != false))) })  as $human_said
    | [ ($pr.comments.nodes[] | {a: (.author.login // ""), b: .body}),
        ($pr.reviews.nodes[]  | {a: (.author.login // ""), b: (.body // "")}) ]
      | map(select(.a == $rbot or (.a | startswith($rbot)))) as $bot_said
    | ($bot_said | map(select(.b | test($clean_re; "i")))
                 | map(select(.b | contains($head[0:7]))) | length > 0) as $bot_clean
    | ([$pr.reviewThreads.nodes[] | select(.actionable)] | length == 0) as $nothing_actionable
    | {
        repo: "'"$REPO"'", pr: $pr.number, title: $pr.title, url: $pr.url,
        state: $pr.state, merged: $pr.merged, is_draft: $pr.isDraft,
        review_decision: ($pr.reviewDecision // "REVIEW_REQUIRED"),
        head_branch: $pr.headRefName, head_sha: $pr.headRefOid,
        base_branch: $pr.baseRefName, pr_author: ($pr.author.login // "unknown"),
        threads_total: ($pr.reviewThreads.nodes | length),
        threads_unresolved: ([$pr.reviewThreads.nodes[] | select(.isResolved | not)] | length),
        threads_actionable: ([$pr.reviewThreads.nodes[] | select(.actionable)] | length),
        threads_actionable_human: ([$pr.reviewThreads.nodes[]
          | select(.actionable and (.is_bot | not))] | length),
        threads_actionable_bot: ([$pr.reviewThreads.nodes[]
          | select(.actionable and .is_bot)] | length),
        threads_awaiting_reviewer: ([$pr.reviewThreads.nodes[]
          | select((.isResolved | not) and (.actionable | not))] | length),
        approved: ($pr.reviewDecision == "APPROVED"),
        blocking_declared: ([ $human_said[]
            | select(.b | test($blk_re; "i"))
            | select(.on_head != false)
            | (.b | [scan($blk_re; "i")] | flatten
                  | map(select(type == "string")) | first | tonumber) ] | last),
        blocking_marker_stale: ([ $human_said[]
            | select((.b | test($blk_re; "i")) and .on_head == false) ] | length > 0),
        threads_blocking_open: ([$pr.reviewThreads.nodes[]
            | select((.isResolved | not) and .blocking == true)] | length),
        threads_actionable_blocking: ([$pr.reviewThreads.nodes[]
            | select(.actionable and .blocking == true)] | length),
        open_by_severity: ([$pr.reviewThreads.nodes[] | select(.isResolved | not)]
            | group_by(.severity // "untagged")
            | map({key: (.[0].severity // "untagged"), value: length}) | from_entries),
        signoff_query_pending: ([ $pr.comments.nodes[]
            | select(.body | contains($qmark + $head)) ] | length > 0),
        review_requested_for_head: ([ $pr.comments.nodes[]
            | select(.body | contains($rmark + $head)) ] | length > 0),
        # The review bot names the commit it read ("Reviewed commit: `617f14db68`"),
        # in a PR comment on a clean pass and in the review body otherwise. The
        # phrase is required, not just the SHA: the bot also keeps a status table
        # that names the head while a review is still running.
        bot_reviewed_head: ($bot_said | map(select(.b | test($reviewed_re; "i")))
            | map(select(.b | contains($head[0:7]))) | length > 0),
        # The clean verdict of the bot on this head. Counted as sign-off below
        # when nothing is actionable, unless PRLOOP_BOT_SIGNOFF=0.
        bot_clean_head: ($bot_said | map(select(.b | test($clean_re; "i")))
            | map(select(.b | contains($head[0:7]))) | length > 0),
        signed_off: (([$human_said[] | select(.counts)] | length > 0)
                     or ($bot_signoff and $bot_clean and $nothing_actionable)),
        signoff_source: ([$human_said[] | select(.counts)
                          | if .mk then "marker" else "phrase" end] | last
                         // (if $bot_signoff and $bot_clean and $nothing_actionable
                             then "bot_clean" else null end)),
        signoff_stale: ([$human_said[]
                         | select(.mk and .on_head == false)] | length > 0),
        signoff_possible: [ $human_said[]
          | select(.hint and (.counts | not))
          | { author: .a,
              excerpt: (.b | gsub("<!--[^>]*-->"; "") | gsub("[[:space:]]+"; " ")
                           | ltrimstr(" ") | .[0:160]) } ],
        stop_requested: ([$human_said[] | select(.b | lines($stop_re))] | length > 0),
        reviewers: ([ ($pr.reviews.nodes[].author.login),
                      ($pr.reviewThreads.nodes[].comments.nodes[].author.login) ]
                    | map(select(. != null)) | unique),
        last_reviewer_activity: ([
            ($pr.reviews.nodes[]  | select((.body // "") | contains($marker) | not) | .submittedAt),
            ($pr.comments.nodes[] | select(.body | contains($marker) | not) | .createdAt),
            ($pr.reviewThreads.nodes[].comments.nodes[]
                                  | select(.body | contains($marker) | not) | .createdAt)
          ] | map(select(. != null)) | sort | last)
      }'
  ;;

threads)
  fetch | jq --arg marker "$MARKER" --argjson bots "$BOTS_JSON" --arg sevre "$SEVERITY_RE" --arg labre "$LABEL_RE" \
             --arg scope "$SCOPE" "$ANNOTATE"'
    | [ .reviewThreads.nodes[]
        | select(
            if   $scope == "all"   then true
            elif $scope == "human" then .actionable and (.is_bot | not)
            elif $scope == "bots"  then .actionable and .is_bot
            else .actionable end)
        | {
            thread_id: .id, path: .path,
            line: (.line // .startLine // .originalLine // .originalStartLine),
            line_is_original: ((.line // .startLine) == null),
            start_line: (.startLine // .originalStartLine), side: .diffSide,
            is_resolved: .isResolved, is_outdated: .isOutdated,
            actionable: .actionable, is_bot: .is_bot,
            severity: .severity, severity_rank: sevrank(.severity),
            blocking: .blocking,
            can_reply: .viewerCanReply, can_resolve: .viewerCanResolve,
            diff_hunk: (.comments.nodes[0].diffHunk // ""),
            comments: [ .comments.nodes[]
              | { author: (.author.login // "unknown"),
                  agent_reply: ((.body // "") | contains($marker)),
                  at: .createdAt, url: .url,
                  body: ((.body // "") | gsub($marker; "") | sub("[[:space:]]+$"; "")) } ]
          } ]
    | sort_by(.is_bot,
              (if .blocking == true then 0 elif .blocking == null then 1 else 2 end),
              sevrank(.severity),
              .path, (.line // 0))'
  ;;

spec)
  fetch | jq --arg marker "$MARKER" '
    .data.repository.pullRequest
    | { pr_title: .title, pr_body: (.body // ""),
        author: (.author.login // "unknown"),
        linked_issues: [ .closingIssuesReferences.nodes[]
          | { number, title, url, body: (.body // "") } ],
        review_summaries: [ .reviews.nodes[]
          | select((.body // "") != "" and ((.body // "") | contains($marker) | not))
          | { author: (.author.login // "unknown"), state: .state,
              at: .submittedAt, body: .body } ] }'
  ;;

reply)
  [[ -n "$THREAD" ]] || { echo "prloop reply: --thread <PRRT_...> is required." >&2; exit 2; }
  [[ -n "$BODY_FILE" ]] && BODY="$(cat "$BODY_FILE")"
  [[ -n "$BODY" ]] || { echo "prloop reply: pass --body <text> or --body-file <path>." >&2; exit 2; }
  BODY="${BODY}"$'\n\n'"${MARKER}"
  "$GH" api graphql \
    -f query='mutation($t:ID!, $b:String!) {
      addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t, body:$b}) {
        comment { url createdAt }
      } }' \
    -f t="$THREAD" -f b="$BODY" \
    --jq '.data.addPullRequestReviewThreadReply.comment | {replied: true, url, at: .createdAt}'
  ;;

comment)
  # PR-level comment, stamped as an agent post so it never reads as reviewer input.
  [[ -n "$BODY_FILE" ]] && BODY="$(cat "$BODY_FILE")"
  [[ -n "$BODY" ]] || { echo "prloop comment: pass --body <text> or --body-file <path>." >&2; exit 2; }
  "$GH" api "repos/$OWNER/$NAME/issues/$PR/comments" \
    -f body="${BODY}"$'\n\n'"${MARKER}" --jq '{posted: true, url: .html_url}'
  ;;

ask-signoff)
  # Asks, on the PR, whether an ambiguous comment was meant as sign-off. Carries a
  # head-keyed marker so `wait` stops re-raising it, which is what lets the loop
  # ask once and go back to waiting instead of interrupting whoever launched it.
  HEAD_SHA="$("$0" status --repo "$REPO" --pr "$PR" | jq -r .head_sha)"
  [[ -n "$BODY_FILE" ]] && BODY="$(cat "$BODY_FILE")"
  [[ -n "$BODY" ]] || BODY="I have nothing actionable left on \`${HEAD_SHA:0:7}\` and read a comment above that may have been a sign-off, but it did not match the sign-off format this loop watches for.

If this PR is done, reply with \`LGTM\` on its own line. If not, leave the findings inline and I will pick them up on the next pass. I am still watching either way."
  "$GH" api "repos/$OWNER/$NAME/issues/$PR/comments" \
    -f body="${BODY}"$'\n\n'"${QUERY_MARKER_PREFIX}${HEAD_SHA} -->"$'\n'"${MARKER}" \
    --jq '{asked: true, url: .html_url}'
  ;;

request-review)
  # Summon the review bot for the current head. Once per head unless --force:
  # the trigger carries a head-keyed marker, so a restarted loop does not ask
  # twice, and a head the bot has already reported on is not re-asked either.
  if [[ "$REVIEW_TRIGGER" == "none" ]]; then
    jq -nc '{requested: false, reason: "no review bot configured (PRLOOP_REVIEW_TRIGGER=none)"}'; exit 0
  fi
  st="$("$0" status --repo "$REPO" --pr "$PR")"
  HEAD_SHA="$(jq -r .head_sha <<<"$st")"
  if (( FORCE == 0 )); then
    if [[ "$(jq -r .review_requested_for_head <<<"$st")" == "true" ]]; then
      jq -c '{requested: false, reason: "already requested for this head", head_sha: .head_sha}' <<<"$st"; exit 0
    fi
    if [[ "$(jq -r .bot_reviewed_head <<<"$st")" == "true" ]]; then
      jq -c '{requested: false, reason: "bot already reviewed this head", head_sha: .head_sha}' <<<"$st"; exit 0
    fi
  fi
  "$GH" api "repos/$OWNER/$NAME/issues/$PR/comments" \
    -f body="${REVIEW_TRIGGER}"$'\n\n'"${REVIEW_MARKER_PREFIX}${HEAD_SHA} -->"$'\n'"${MARKER}" \
    --jq "{requested: true, head_sha: \"${HEAD_SHA}\", url: .html_url}"
  ;;

resolve)
  [[ -n "$THREAD" ]] || { echo "prloop resolve: --thread <PRRT_...> is required." >&2; exit 2; }
  "$GH" api graphql \
    -f query='mutation($t:ID!) {
      resolveReviewThread(input:{threadId:$t}) { thread { id isResolved } } }' \
    -f t="$THREAD" \
    --jq '.data.resolveReviewThread.thread | {thread_id: .id, resolved: .isResolved}'
  ;;

wait)
  # Blocks until the reviewer does something worth waking up for, then exits 0
  # printing a single JSON line. Run this with Bash run_in_background so the one
  # exit notification is the wake-up call. It checks before the first sleep, so a
  # reviewer who already commented does not sit through a backoff interval.
  read -r -a delays <<<"${PRLOOP_DELAYS:-120 240 480 960 1800}"
  elapsed=0; i=0
  while :; do
    st="$("$0" status --repo "$REPO" --pr "$PR" 2>/dev/null || true)"
    if [[ -n "$st" ]]; then
      reason="$(jq -r '
        if   .signed_off        then "signed_off"
        elif .approved          then "approved"
        elif .merged            then "merged"
        elif .state != "OPEN"   then "closed"
        elif .stop_requested    then "stop_requested"
        elif .threads_actionable > 0 then "new_comments"
        elif (.signoff_possible | length) > 0 and (.signoff_query_pending | not)
                                     then "signoff_unclear"
        else "" end' <<<"$st" 2>/dev/null || true)"
      if [[ -n "$reason" ]]; then
        jq -c --arg r "$reason" --argjson w "$elapsed" \
          '{woke: $r, waited_seconds: $w} + .' <<<"$st"
        exit 0
      fi
    fi
    if (( MAX_WAIT > 0 && elapsed >= MAX_WAIT )); then
      echo "{\"woke\":\"timeout\",\"waited_seconds\":$elapsed,\"pr\":$PR,\"repo\":\"$REPO\"}"
      exit 0
    fi
    d=${delays[$i]:-1800}
    (( i < ${#delays[@]} - 1 )) && ((i++)) || true
    sleep "$d"
    elapsed=$((elapsed + d))
  done
  ;;

*)
  echo "prloop: unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac
