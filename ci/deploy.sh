#!/bin/bash
# One consumer commit per FlexKernels commit since its VERSION that changes its kernels
# Usage: ci/deploy.sh <consumer-dir> <cuda|cuda-restir|wgsl|glsl>:<vendored-path>...
set -euo pipefail
consumer=$1
shift
tree=$(mktemp -d)
git worktree add -q --detach "$tree"
mkdir -p .deps
ln -s "$PWD/.deps" "$tree/.deps"
git -C "$consumer" config user.name "$(git log -1 --format=%cn)"
git -C "$consumer" config user.email "$(git log -1 --format=%ce)"
# Only commits to the sources and the Makefile can change the kernels
for sha in $(git rev-list --reverse "$(cat "$consumer/${1#*:}/VERSION")..HEAD" -- src Makefile); do
    git -C "$tree" checkout -q "$sha"
    make -C "$tree" -s clean all
    versions=()
    for target in "$@"; do
        # Targets a commit does not generate keep what is vendored
        [ -d "$tree/build/${target%%:*}" ] || continue
        vendored=${target#*:}
        git -C "$consumer" rm -rq --ignore-unmatch "$vendored"
        mkdir -p "$consumer/$vendored"
        cp "$tree/build/${target%%:*}"/* "$consumer/$vendored"
        echo "$sha" > "$consumer/$vendored/VERSION"
        git -C "$consumer" add "$vendored"
        versions+=(":!$vendored/VERSION")
    done
    if git -C "$consumer" diff --cached --quiet -- . "${versions[@]}"; then
        git -C "$consumer" reset -q --hard
        continue
    fi
    case ${1%%:*} in
        cuda*) make -C "$consumer" ;;
        wgsl) (cd "$consumer" && bash ./build-script) ;;
    esac
    GIT_COMMITTER_DATE=$(git log -1 --format=%cI "$sha") git -C "$consumer" commit -q -m "$(git log -1 --format=%B "$sha")" \
        --author="$(git log -1 --format='%an <%ae>' "$sha")" --date="$(git log -1 --format=%aI "$sha")"
done
git worktree remove --force "$tree"
git -C "$consumer" push origin HEAD:main || { git -C "$consumer" pull --rebase origin main && git -C "$consumer" push origin HEAD:main; }
