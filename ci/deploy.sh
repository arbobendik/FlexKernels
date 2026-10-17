#!/bin/bash
# One consumer commit per FlexKernels commit since its VERSION that changes its kernels
# Usage: ci/deploy.sh <consumer-dir> <cuda|cuda-restir|wgsl|glsl>:<vendored-path>...
set -euo pipefail
consumer=$1 source=$2 vendored=$3
tree=$(mktemp -d)
git worktree add -q --detach "$tree"
mkdir -p .deps
ln -s "$PWD/.deps" "$tree/.deps"
git -C "$consumer" config user.name "$(git log -1 --format=%cn)"
git -C "$consumer" config user.email "$(git log -1 --format=%ce)"
# Only commits to the sources and the Makefile can change the kernels
for sha in $(git rev-list --reverse "$(cat "$consumer/$vendored/VERSION")..HEAD" -- src Makefile); do
    git -C "$tree" checkout -q "$sha"
    make -C "$tree" -s clean all
    git -C "$consumer" rm -rq "$vendored"
    mkdir -p "$consumer/$vendored"
    cp "$tree/build/$source"/* "$consumer/$vendored"
    echo "$sha" > "$consumer/$vendored/VERSION"
    git -C "$consumer" add "$vendored"
    if git -C "$consumer" diff --cached --quiet -- . ":!$vendored/VERSION"; then
        git -C "$consumer" reset -q --hard
        continue
    fi
    case $source in
        cuda) make -C "$consumer" ;;
        wgsl) (cd "$consumer" && bash ./build-script) ;;
    esac
    GIT_COMMITTER_DATE=$(git log -1 --format=%cI "$sha") git -C "$consumer" commit -q -m "$(git log -1 --format=%B "$sha")" \
        --author="$(git log -1 --format='%an <%ae>' "$sha")" --date="$(git log -1 --format=%aI "$sha")"
done
git worktree remove --force "$tree"
git -C "$consumer" push origin HEAD:main || { git -C "$consumer" pull --rebase origin main && git -C "$consumer" push origin HEAD:main; }
