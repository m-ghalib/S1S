#!/bin/bash
# Print the next S1S version for a bump kind.
# Usage: next-version.sh <release|hotfix|current>   (run from the repo root)
#   release  0.1.4 -> 0.1.5, 0.1.4.2 -> 0.1.5   (third number +1, fourth dropped)
#   hotfix   0.1.4 -> 0.1.4.1, 0.1.4.1 -> 0.1.4.2
#   current  keep the Info.plist version (for a version that was bumped but never tagged)
# Also reports, on stderr, the current version, the latest tag, and whether the
# current version is already tagged. Exits 1 if the result is already tagged.
set -euo pipefail
KIND="${1:-}"
PLIST="Resources/Info.plist"
CUR="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
IFS=. read -r A B C D <<<"$CUR"
C="${C:-0}"

case "$KIND" in
  release) NEXT="$A.$B.$((C + 1))" ;;
  hotfix)  NEXT="$A.$B.$C.$(( ${D:-0} + 1 ))" ;;
  current) NEXT="$CUR" ;;
  *) echo "usage: $0 <release|hotfix|current>" >&2; exit 2 ;;
esac

LATEST_TAG="$(git tag --list 'v*' --sort=-v:refname | head -1)"
CUR_TAGGED=no; git rev-parse -q --verify "refs/tags/v$CUR" >/dev/null && CUR_TAGGED=yes
echo "current=$CUR tagged=$CUR_TAGGED latest_tag=${LATEST_TAG:-none}" >&2

if git rev-parse -q --verify "refs/tags/v$NEXT" >/dev/null; then
  echo "v$NEXT is already tagged; pick another bump." >&2; exit 1
fi
echo "$NEXT"
