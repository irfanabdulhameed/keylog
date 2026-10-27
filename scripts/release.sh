#!/bin/bash
# Makes a Keylog release on this Mac and publishes it on GitHub.
#
#   ./scripts/release.sh [patch|minor|major] [--notes FILE] [--dry-run]
#
#   patch | minor | major  which part of the version goes up: 1.0.3 becomes 1.0.4, 1.1.0 or 2.0.0.
#                          Not needed while the version in Resources/Info.plist hasn't been
#                          released yet (the first release, 1.0.0): it is released as it is.
#   --notes FILE           the release notes, in Markdown. Without it: the subjects of the commits
#                          since the last release that touch the app (Sources, Resources,
#                          Package.swift), one line each.
#   --dry-run              everything except pushing and publishing. The release commit and tag
#                          are taken back at the end; build/Keylog.dmg stays, to look at.
#
# Steps: checks that the tree is clean, on main and the same as origin/main; sets the version and
# build number in Info.plist and commits "Release X.Y.Z"; builds build/Keylog.dmg; tags vX.Y.Z;
# checks the new commits (author, committer, words); pushes the commit and the tag; creates the
# GitHub release "Keylog X.Y.Z" with Keylog.dmg attached. The app must be signed with the
# "Keylog Dev" certificate, the one every copy is checked against when it updates. Anything that
# fails before the push takes the release commit and tag back.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="irfanabdulhameed/keylog"
NAME="Irfan Abdul Hameed"
EMAIL="63074485+irfanabdulhameed@users.noreply.github.com"
PLIST="Resources/Info.plist"
# Optional: a private list of words no commit or release note may contain, as one extended
# regular expression, kept outside the repo. Without it the word check is skipped.
WORDS_FILE="${KEYLOG_PRIVATE_WORDS:-$HOME/.config/keylog/forbidden-words}"
[ -r "$WORDS_FILE" ] || WORDS_FILE="$HOME/.config/clover/forbidden-words"
WORDS=""
if [ -r "$WORDS_FILE" ]; then WORDS="$(tr -d '\n' < "$WORDS_FILE")"; fi

LEVEL=""
NOTES_FILE=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    patch|minor|major) LEVEL="$1" ;;
    --notes) NOTES_FILE="${2:?--notes needs a file}"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "release: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

fail() { echo "release: $*" >&2; exit 1; }
say() { echo "==> $*"; }
plist_get() { plutil -extract "$1" raw -o - "${2:-$PLIST}"; }
# Changes one string in place, keeping the file's order and layout.
plist_set() { perl -0pi -e "s|(<key>$1</key>\\s*<string>)[^<]*(</string>)|\${1}$2\${2}|" "$PLIST"; }

# 1. A clean tree on main, the same as GitHub, and the right identity.
[ -z "$(git status --porcelain)" ] || fail "the tree has changes; commit or stash them first"
[ "$(git symbolic-ref --short HEAD 2>/dev/null || true)" = main ] || fail "not on main"
git fetch --quiet --tags origin || fail "couldn't fetch from origin"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main isn't the same as origin/main; push or pull first"
[ "$(git config user.name)" = "$NAME" ] && [ "$(git config user.email)" = "$EMAIL" ] || fail "git's identity isn't $NAME <$EMAIL>"
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || fail "no notes file at $NOTES_FILE"
if [ $DRY = 0 ]; then
  command -v gh >/dev/null || fail "gh isn't installed"
  [ "$(gh api user --jq .login 2>/dev/null)" = irfanabdulhameed ] || fail "gh isn't logged in as irfanabdulhameed"
fi

# 2. The version.
CURRENT="$(plist_get CFBundleShortVersionString)"
BUILD="$(plist_get CFBundleVersion)"
[[ "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "Info.plist's version $CURRENT isn't X.Y.Z"
MAJOR=${BASH_REMATCH[1]}; MINOR=${BASH_REMATCH[2]}; PATCH=${BASH_REMATCH[3]}
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "Info.plist's build number $BUILD isn't a whole number"
LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"

if git rev-parse -q --verify "refs/tags/v$CURRENT" >/dev/null; then
  case "$LEVEL" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    *) fail "$CURRENT is released already: say patch, minor or major" ;;
  esac
  VERSION="$MAJOR.$MINOR.$PATCH"
  NEW_BUILD=$((BUILD + 1))
else
  VERSION="$CURRENT"
  NEW_BUILD=$BUILD
  [ -z "$LEVEL" ] || say "$CURRENT hasn't been released yet, so it is released as it is ($LEVEL applies next time)"
fi
if [ -n "$LAST_TAG" ]; then
  # Newer than the last release, with a higher build number.
  [ "$VERSION" != "${LAST_TAG#v}" ] && [ "$(printf '%s\n%s\n' "${LAST_TAG#v}" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] \
    || fail "$VERSION isn't newer than $LAST_TAG"
  LAST_BUILD="$(git show "$LAST_TAG:$PLIST" | plutil -extract CFBundleVersion raw -o - - 2>/dev/null || echo 0)"
  [ "$NEW_BUILD" -gt "$LAST_BUILD" ] || NEW_BUILD=$((LAST_BUILD + 1))
fi
TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG exists already"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && fail "$TAG exists on GitHub already"
say "Releasing Keylog $VERSION (build $NEW_BUILD)${LAST_TAG:+, after $LAST_TAG}$([ $DRY = 1 ] && echo ', dry run')"

# 3. The notes, kept in build/ so a failed upload can be retried.
mkdir -p build
NOTES="build/release-notes-$VERSION.md"
if [ -n "$NOTES_FILE" ]; then
  cp "$NOTES_FILE" "$NOTES"
elif [ -n "$LAST_TAG" ]; then
  git log --no-merges --format='- %s' "$LAST_TAG..HEAD" -- Sources Resources Package.swift \
    | grep -v -E '^- Release [0-9]+\.[0-9]+\.[0-9]+$' > "$NOTES" || true
  [ -s "$NOTES" ] || fail "nothing in the app has changed since $LAST_TAG"
else
  echo "- The first release of Keylog." > "$NOTES"
fi
[ -z "$WORDS" ] || ! grep -i -n -E "$WORDS" "$NOTES" || fail "the notes contain words that must not be published"

# Anything that fails before the push takes back what this run made. So does a dry run.
START="$(git rev-parse HEAD)"
COMMITTED=0
TAGGED=0
PUSHED=0
finish() {
  local status=$?
  if [ $PUSHED = 0 ] && { [ $DRY = 1 ] || [ $status != 0 ]; }; then
    if [ $TAGGED = 1 ]; then git tag -d "$TAG" >/dev/null; fi
    if [ $COMMITTED = 1 ]; then git reset --quiet --keep "$START"; else git checkout --quiet -- "$PLIST"; fi
    if [ $TAGGED = 1 ] || [ $COMMITTED = 1 ]; then echo "==> Took back the release commit and tag"; fi
  fi
  exit $status
}
trap finish EXIT

# 4. The release commit, as Irfan.
export GIT_AUTHOR_NAME="$NAME" GIT_AUTHOR_EMAIL="$EMAIL" GIT_COMMITTER_NAME="$NAME" GIT_COMMITTER_EMAIL="$EMAIL"
plist_set CFBundleShortVersionString "$VERSION"
plist_set CFBundleVersion "$NEW_BUILD"
[ "$(plist_get CFBundleShortVersionString)" = "$VERSION" ] && [ "$(plist_get CFBundleVersion)" = "$NEW_BUILD" ] \
  || fail "couldn't set the version in $PLIST"
if git diff --quiet -- "$PLIST"; then
  say "Info.plist already says $VERSION ($NEW_BUILD): no release commit"
else
  git commit --quiet -m "Release $VERSION" -- "$PLIST"
  COMMITTED=1
  say "Committed Release $VERSION"
fi

# 5. The disk image, holding this version.
./scripts/make-dmg.sh
[ "$(plist_get CFBundleShortVersionString build/Keylog.app/Contents/Info.plist)" = "$VERSION" ] || fail "the built app isn't $VERSION"
# Input Monitoring belongs to the signing certificate, and the updater only installs a copy signed
# like the running one: every release must carry the same certificate.
codesign -dvv build/Keylog.app 2>&1 | grep -q "^Authority=${KEYLOG_SIGN_ID:-Keylog Dev}$" \
  || fail "build/Keylog.app isn't signed with \"${KEYLOG_SIGN_ID:-Keylog Dev}\" (run scripts/make-cert.sh); an ad-hoc release can't update anyone"
[ -z "$(git status --porcelain)" ] || fail "building changed tracked files"

# 6. The tag.
git tag -a "$TAG" -m "Keylog $VERSION"
TAGGED=1
say "Tagged $TAG"

# 7. Everything that would be pushed: Irfan's identity only, and none of the words.
RANGE="origin/main..HEAD"
BAD=0
WHO="$(git log --format='%h|%an|%ae|%cn|%ce' "$RANGE" | awk -F'|' -v n="$NAME" -v e="$EMAIL" '$2!=n || $3!=e || $4!=n || $5!=e')"
[ -z "$WHO" ] || { echo "Commits not under $NAME <$EMAIL>:"; echo "$WHO"; BAD=1; }
TAGGER="$(git for-each-ref "refs/tags/$TAG" --format='%(taggername)|%(taggeremail)')"
[ "$TAGGER" = "$NAME|<$EMAIL>" ] || { echo "The tag isn't by $NAME <$EMAIL>: $TAGGER"; BAD=1; }
MESSAGES="$(git log --format='%h %B' "$RANGE"; git for-each-ref "refs/tags/$TAG" --format='%(contents)')"
[ -z "$WORDS" ] || ! echo "$MESSAGES" | grep -i -E "$WORDS" || BAD=1
[ -z "$WORDS" ] || ! git diff "origin/main...HEAD" | grep '^+' | grep -v '^+++' | grep -i -E "$WORDS" || BAD=1
[ $BAD = 0 ] || fail "the check found the problems above"
say "Checked $(git rev-list --count "$RANGE") new commit(s) and the tag: clean"

if [ $DRY = 1 ]; then
  say "Dry run: would now run"
  echo "    git push --atomic origin main refs/tags/$TAG"
  echo "    gh release create $TAG build/Keylog.dmg --repo $REPO --title \"Keylog $VERSION\" --notes-file $NOTES --verify-tag"
  say "Notes ($NOTES):"
  sed 's/^/    /' "$NOTES"
  exit 0
fi

# 8. Push, then publish.
git push --atomic origin main "refs/tags/$TAG"
PUSHED=1
gh release create "$TAG" build/Keylog.dmg --repo "$REPO" --title "Keylog $VERSION" --notes-file "$NOTES" --verify-tag \
  || fail "pushed, but the GitHub release wasn't made. Run again by hand:
    gh release create $TAG build/Keylog.dmg --repo $REPO --title \"Keylog $VERSION\" --notes-file $NOTES --verify-tag"
say "Published Keylog $VERSION: https://github.com/$REPO/releases/tag/$TAG"
