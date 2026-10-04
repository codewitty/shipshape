# GitHub review-thread API notes

Read this when `scripts/prloop.sh` cannot do what you need: a thread shape it does
not model, an error you have to interpret, or a call you want to make by hand.

## Vocabulary

GitHub has three separate comment surfaces on a pull request, and they are not
interchangeable:

| Surface | Where it appears | API |
|---|---|---|
| Review thread comment | Anchored to a file and line in the diff | `reviewThreads` (GraphQL) / `pulls/{n}/comments` (REST) |
| Review summary | The body of a submitted review, above the file comments | `reviews` (GraphQL) / `pulls/{n}/reviews` (REST) |
| Issue comment | The bottom of the Conversation tab | `comments` (GraphQL) / `issues/{n}/comments` (REST) |

The loop is built around review threads because those carry a line anchor and a
resolved bit. `prloop spec` surfaces review summaries, which often carry the
reviewer's framing for the whole pass. `prloop status` scans all three for the
stop word.

## Identifiers

Threads use GraphQL node IDs shaped `PRRT_kwDO...`. Individual comments have both
a node ID (`PRRC_...`) and a `databaseId` integer. The reply and resolve mutations
take the **thread** ID, so `databaseId` is only needed for the REST fallback below.

## Fetching threads

```bash
gh api graphql -f query='
query($owner:String!, $name:String!, $pr:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$pr) {
      reviewDecision state merged headRefOid
      reviewThreads(first:100) {
        nodes {
          id isResolved isOutdated path line startLine diffSide
          viewerCanReply viewerCanResolve
          comments(first:50) {
            nodes { databaseId url author { login } body createdAt diffHunk }
          }
        }
      }
    }
  }
}' -F owner=OWNER -F name=NAME -F pr=123
```

`reviewThreads(first:100)` covers essentially every real PR. If a PR somehow
exceeds 100 threads, page with `after:` and the `pageInfo.endCursor`.

## Replying to a thread

```bash
gh api graphql -f query='
mutation($t:ID!, $b:String!) {
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t, body:$b}) {
    comment { url createdAt }
  } }' -f t="PRRT_..." -f b="Fixed in abc1234."
```

`pullRequestReviewId` is an optional input. Leaving it out posts the reply
immediately instead of attaching it to a pending review, which is what you want:
a pending review stays invisible to the reviewer until submitted.

REST fallback, if the mutation is unavailable. It needs the `databaseId` of the
thread's **first** comment, not the thread ID:

```bash
gh api --method POST repos/OWNER/NAME/pulls/123/comments/1583153997/replies -f body="..."
```

## Resolving a thread

```bash
gh api graphql -f query='
mutation($t:ID!) { resolveReviewThread(input:{threadId:$t}) { thread { isResolved } } }' \
  -f t="PRRT_..."
```

There is no REST equivalent. `unresolveReviewThread` takes the same input and
undoes it. Check `viewerCanResolve` first: on some repos only the thread author
and users with write access can resolve.

## Telling your own replies apart from the reviewer's comments

There is no API field for "did I write this". The obvious substitute, comparing
`author.login` against `gh api user --jq .login`, fails on a solo PR: the human
reviews their own branch from the same account the agent is authenticated as, so
every comment has the same login and the reviewer's blocking notes look like the
agent's own replies.

`prloop.sh reply` therefore appends an HTML comment to every reply it posts:

```html
<!-- prloop:agent-reply -->
```

GitHub renders HTML comments as nothing, so the reviewer never sees it, and the
string survives the API round trip untouched. Any code deciding whether a thread
still needs attention should test for that marker rather than for a login.

Override it with `PRLOOP_MARKER` if it collides with something. Replies posted
before the marker existed will read as reviewer comments, which surfaces them for
one extra round rather than hiding them. That is the right way for the failure to
go.

## Approval state

`reviewDecision` is the field to trust. It collapses every reviewer's latest
review into one of `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or `null`
when no review is required. Reading the `reviews` list yourself is a trap: a
reviewer who approves and later comments still shows a `COMMENTED` review as the
most recent entry while `reviewDecision` correctly stays `APPROVED`.

`state` is `OPEN`, `CLOSED`, or `MERGED`. `merged` is the boolean form.

**GitHub will not let an account approve a pull request it opened.** Submitting a
review with `event: APPROVE` on your own PR fails, and the web UI hides the
option. On a solo PR, `reviewDecision` therefore sits at `REVIEW_REQUIRED` no
matter how satisfied the reviewer is, and any loop waiting for `APPROVED` waits
forever. This is why sign-off is detected from a phrase in a comment instead. See
the "Ending the loop" section of `SKILL.md`.

## Outdated threads

`isOutdated: true` means the lines the comment anchored to have changed since it
was written, usually because you already pushed a fix. GitHub nulls out `line`
and `startLine` on these threads. Fall back to `originalLine` and
`originalStartLine`, which hold the position in the diff the comment was written
against, and read `diffHunk` to find the code in the current file. The comment is still live
and still needs a reply. Do not skip outdated threads. GitHub collapses them in
the web UI, so an unanswered outdated thread is easy for the reviewer to lose,
which makes replying to it more valuable, not less.

## Token scopes

Everything here needs the `repo` scope. Check with `gh auth status`. If replies
fail with `Resource not accessible by integration`, the token is missing write
access to the repo rather than the API being wrong.

## Rate limits

The GraphQL query above costs 1 point. Polling every two minutes for hours is
well inside the 5,000 points/hour limit. `gh api rate_limit` shows the current
budget if you suspect throttling.
