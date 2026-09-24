#!/usr/bin/env bash
# Publish the current Ngate2VPN build (DMG) to GitHub Releases.
#
# Requirements:
#   - git
#   - GitHub CLI: https://cli.github.com/
#   - Optional GH_TOKEN for non-interactive auth
#
# Token permissions for a private repo:
#   - Contents: Read and write
#   - Metadata: Read-only
#
# Usage:
#   export GH_TOKEN="github_pat_..."
#   ./Scripts/publish_github_release.sh
#
# Optional overrides:
#   VERSION=4.00 REPO=MoonMig/Ngate2VPN BRANCH=main ./Scripts/publish_github_release.sh
#
# VERSION defaults to APP_VERSION in build-app.sh; the release notes are the
# newest section of CHANGELOG.md.

set -euo pipefail

REPO="${REPO:-MoonMig/Ngate2VPN}"
REMOTE_URL="${REMOTE_URL:-https://github.com/${REPO}.git}"
BRANCH="${BRANCH:-main}"
VERSION="${VERSION:-$(sed -n 's/^APP_VERSION="\(.*\)"/\1/p' build-app.sh | head -1)}"
TAG="${TAG:-v${VERSION}}"
RELEASE_TITLE="${RELEASE_TITLE:-v${VERSION}}"
APP_NAME="Ngate2VPN"
DIST_DIR="dist"
ARCHIVE="build/${APP_NAME}-${VERSION}.dmg"
RELEASE_NOTES="${DIST_DIR}/release-notes-${TAG}.md"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: '$1' is required" >&2
        exit 1
    fi
}

need git
need gh

if [[ ! -d .git ]]; then
    echo "error: release publishing must run from an existing git repository." >&2
    echo "       Commit and push the source intentionally before running this script." >&2
    exit 1
fi

current_branch="$(git branch --show-current)"
if [[ "$current_branch" != "$BRANCH" ]]; then
    echo "error: current branch is '${current_branch}', expected '${BRANCH}'." >&2
    echo "       Set BRANCH=${current_branch} if this is intentional." >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree has uncommitted changes." >&2
    echo "       Commit or stash them before publishing a release." >&2
    exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
    echo "error: git remote 'origin' is not configured." >&2
    exit 1
fi

current_remote="$(git remote get-url origin)"
if [[ "$current_remote" != "$REMOTE_URL" ]]; then
    echo "error: origin remote is '${current_remote}', expected '${REMOTE_URL}'." >&2
    echo "       Override REPO/REMOTE_URL if this is intentional." >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    if [[ -z "${GH_TOKEN:-}" ]]; then
        echo "error: GitHub CLI is not authenticated. Run 'gh auth login' or set GH_TOKEN." >&2
        exit 1
    fi
    echo "==> Authenticating GitHub CLI with GH_TOKEN..."
    printf '%s\n' "$GH_TOKEN" | gh auth login --with-token
fi
echo "==> Pushing ${BRANCH} to ${REPO}..."
git push -u origin "$BRANCH"

echo "==> Building app bundle and DMG..."
./build-app.sh release

if [[ ! -f "$ARCHIVE" ]]; then
    echo "error: expected DMG at ${ARCHIVE}" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"

echo "==> Preparing release notes..."
awk '
    /^## / {
        if (seen) { exit }
        seen = 1
    }
    seen { print }
' CHANGELOG.md > "$RELEASE_NOTES"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "==> Tag ${TAG} already exists locally."
else
    echo "==> Creating tag ${TAG}..."
    git tag -a "$TAG" -m "$RELEASE_TITLE"
fi

echo "==> Pushing tag ${TAG}..."
git push origin "$TAG"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "==> Release ${TAG} exists. Uploading archive with clobber..."
    gh release upload "$TAG" "$ARCHIVE" --repo "$REPO" --clobber
else
    echo "==> Creating GitHub Release ${TAG}..."
    gh release create "$TAG" "$ARCHIVE" \
        --repo "$REPO" \
        --title "$RELEASE_TITLE" \
        --notes-file "$RELEASE_NOTES"
fi

echo ""
echo "Done:"
echo "  Repository: https://github.com/${REPO}"
echo "  Release:    https://github.com/${REPO}/releases/tag/${TAG}"
echo "  Asset:      ${ARCHIVE}"
