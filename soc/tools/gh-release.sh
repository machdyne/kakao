#!/bin/sh
# Publish a release made by release.sh as the GitHub release TAG
# (soc/docs/releases.md).
#
#   soc/tools/gh-release.sh v0.1            publish
#   soc/tools/gh-release.sh v0.1 --draft    a draft, to look at first
#   soc/tools/gh-release.sh v0.1 -o <dir>   from <dir>, not soc/boards/build/release
#
# Needs the GitHub CLI, logged in (gh auth login). The tag is made here
# (on the commit checked out) and pushed, if it isn't already.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
out=$here/../boards/build/release
TAG=${1:-}
[ -n "$TAG" ] || { echo "usage: soc/tools/gh-release.sh TAG [--draft] [-o <dir>]"; exit 1; }
shift
DRAFT=""
while [ $# -gt 0 ]; do
	case $1 in
	--draft) DRAFT="--draft";;
	-o) out=$2; shift;;
	*) echo "gh-release: what is $1?"; exit 1;;
	esac
	shift
done
cd "$top"
[ -f "$out/SHA256SUMS" ] || { echo "gh-release: nothing in $out: run make -C soc/boards release RELEASE=\"-t $TAG\" first"; exit 1; }
python3 -c "import json,sys; sys.exit(0 if json.load(open('$out/MANIFEST.json'))['version'] == '$TAG' else 1)" || {
	echo "gh-release: $out was made for another tag: make it again with -t $TAG"; exit 1; }
(cd "$out" && sha256sum --quiet -c SHA256SUMS) || { echo "gh-release: a file differs from SHA256SUMS"; exit 1; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "gh-release: there are uncommitted changes: commit them first, then make the release again"
	exit 1
fi
command -v gh >/dev/null 2>&1 || { echo "gh-release: the GitHub CLI (gh) is missing"; exit 1; }

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	git tag -a "$TAG" -m "Kakao $TAG"
fi
git push origin "refs/tags/$TAG"

files=$(cd "$out" && ls kakao-* THIRD-PARTY.txt MANIFEST.json SUMMARY.md SHA256SUMS)
(cd "$out" && gh release create "$TAG" $DRAFT --verify-tag --title "Kakao $TAG" --notes-file SUMMARY.md $files)
echo "gh-release: published $TAG${DRAFT:+ (draft)}"
