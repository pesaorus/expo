#!/usr/bin/env bash
# Count the automatic AI reviews of one PR, and stop them at a limit.
#
# The count is a hidden marker at the end of the reviewer's own PR comment. Only
# expo-bot and maintainers can edit that comment, so a PR author cannot reset it.
# ecr rewrites the whole comment on each review, so `record` adds the marker back.
# A review that ecr runs without `record`, such as `@expo-bot review`, drops the
# marker, and that resets the count.
#
#   check   Writes skip=true|false and next=<count> to $GITHUB_OUTPUT.
#   record  Writes next=<count> back into the comment.
#
# Env: GH_TOKEN, REPO, PR, BOT_LOGIN, COMMENT_TAG, and for `check`: COUNTED, MAX.
set -euo pipefail

START='<!-- expo-ai-review-auto-count:start -->'

# The body without our block. ecr escapes `<!--` in all PR text, so the start
# marker can only be ours.
strip_block() {
  awk -v start="$START" 'index($0, start) { exit } { print }'
}

read_count() {
  { grep -o '<!-- expo-ai-review-auto-count=[0-9]* -->' || true; } | tail -n 1 | tr -dc '0-9'
}

# Prints the body with a new block: an optional visible note and the count.
with_block() {
  local body=$1 count=$2 note=${3:-}
  printf '%s\n\n%s\n' "$(strip_block <<< "$body")" "$START"
  [ -z "$note" ] || printf '%s\n' "$note"
  printf '<!-- expo-ai-review-auto-count=%s -->\n' "$count"
}

if [ "${1:-}" = --self-test ]; then
  body=$'Review\n<!-- tag:state=abc -->'
  marked=$(with_block "$body" 3)
  [ "$(read_count <<< "$marked")" = 3 ]
  remarked=$(with_block "$marked" 4 'Paused.')
  [ "$(read_count <<< "$remarked")" = 4 ]
  [ "$(grep -c 'expo-ai-review-auto-count:start' <<< "$remarked")" = 1 ]
  [ "$(strip_block <<< "$remarked")" = "$body" ]
  [ -z "$(read_count <<< "$body")" ]
  [ -z "$(read_count <<< "")" ]
  echo "ai-review-auto-count self-test ok"
  exit 0
fi

: "${GH_TOKEN:?}" "${REPO:?}" "${PR:?}" "${BOT_LOGIN:?}" "${COMMENT_TAG:?}"
marker="<!-- $COMMENT_TAG -->"

# The id of the reviewer's comment, as ecr picks it: the last one by the bot with the marker.
comment_id() {
  gh api --paginate "repos/$REPO/issues/$PR/comments" \
    --jq ".[] | select(.user.login == \"$BOT_LOGIN\" and (.body | contains(\"$marker\"))) | .id" |
    tail -n 1
}

write_body() {
  jq -n --arg body "$2" '{body: $body}' |
    gh api -X PATCH "repos/$REPO/issues/comments/$1" --input - > /dev/null
}

case "${1:-}" in
  check)
    : "${COUNTED:?}" "${MAX:?}"
    # A failed read reviews as usual. A PR author cannot cause it, so it is no way around the limit.
    id=$(comment_id) || { echo "::warning::Could not read the AI review comment. The limit is not checked."; id=""; }
    body=""
    [ -z "$id" ] || body=$(gh api "repos/$REPO/issues/comments/$id" --jq .body) || body=""
    count=$(read_count <<< "$body")
    count=${count:-0}
    if [ "$COUNTED" != true ]; then
      # A label event comes from a maintainer, or from expo-bot on a review request.
      echo "skip=false" >> "$GITHUB_OUTPUT"
      echo "next=0" >> "$GITHUB_OUTPUT"
    elif [ "$count" -ge "$MAX" ]; then
      echo "Automatic AI review limit reached ($count of $MAX). Skipping this review."
      note="> [!NOTE]
> Automatic AI reviews are paused on this PR: it used $count of $MAX. To review the latest commit, a maintainer can comment \`@expo-bot review\` or re-request expo-bot's review. That also resets the count."
      write_body "$id" "$(with_block "$body" "$count" "$note")" ||
        echo "::warning::Could not add the limit note to the AI review comment."
      echo "skip=true" >> "$GITHUB_OUTPUT"
    else
      echo "Automatic AI review $((count + 1)) of $MAX."
      echo "skip=false" >> "$GITHUB_OUTPUT"
      echo "next=$((count + 1))" >> "$GITHUB_OUTPUT"
    fi
    ;;
  record)
    : "${NEXT:?}"
    id=$(comment_id)
    if [ -z "$id" ]; then
      echo "::warning::The review posted no comment, so this review is not counted."
      exit 0
    fi
    write_body "$id" "$(with_block "$(gh api "repos/$REPO/issues/comments/$id" --jq .body)" "$NEXT")"
    ;;
  *)
    echo "usage: $0 check|record|--self-test" >&2
    exit 2
    ;;
esac
