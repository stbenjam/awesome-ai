#!/usr/bin/env bash
# Resolve a GitHub PR review thread using the GraphQL API.
#
# Usage: resolve_comments.sh <thread_node_id>
#
# The thread_node_id is the GraphQL node ID of the review thread
# (starts with "PRRT_" or similar). This is returned by fetch_comments.py
# in the thread_node_id field.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <thread_node_id>" >&2
    exit 1
fi

THREAD_NODE_ID="$1"

gh api graphql -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      id
      isResolved
    }
  }
}' -f threadId="$THREAD_NODE_ID" --jq '.data.resolveReviewThread.thread | {id, isResolved}'
