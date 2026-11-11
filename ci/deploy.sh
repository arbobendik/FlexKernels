#!/bin/bash
# Deploys the kernels into a consumer checked out on its main: for each FlexKernels commit since its VERSION that
# changes its generated kernels, one commit with that commit's message, author and dates. Each generates the kernels
# in a worktree of its commit, replaces the vendored directory with them and builds the consumer as its own CI does, so
# that a broken kernel never reaches its main; they are pushed together. Run from FlexKernels checked out with full
# history, as CI and the local rehearsal do. Each target is a source of build/ and the directory it is vendored to, the
# first's VERSION the consumer's and its source how the consumer builds.
# A change to a hook's signature or meaning lands through a paired consumer PR, vendoring this repository's PR run's
# build artifact with the consumer's side of the hook, merged first; the FlexKernels PR then merges by fast-forward, so
# this script finds the consumer current and pushes nothing. Vendor CI's files: a module's digest depends on the
# toolchain's path.
# Usage: ci/deploy.sh <consumer-dir> <cuda|cuda-restir|wgsl|glsl>:<vendored-path>...
set -euo pipefail
consumer=$1
shift
tree=$(mktemp -d)
git worktree add -q --detach "$tree"
# Slang is fetched once, by version, for all of them
mkdir -p .deps
ln -s "$PWD/.deps" "$tree/.deps"
# The identity FlexKernels is committed with, for the rebase below
git -C "$consumer" config user.name "$(git log -1 --format=%cn)"
git -C "$consumer" config user.email "$(git log -1 --format=%ce)"
# Only commits to the sources and the Makefile can change the kernels
for sha in $(git rev-list --reverse "$(cat "$consumer/${1#*:}/VERSION")..HEAD" -- src Makefile); do
    git -C "$tree" checkout -q "$sha"
    make -C "$tree" -s clean all
    versions=()
    for target in "$@"; do
        # A target the commit does not generate yet, as before the GLSL target, keeps what is vendored
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
