#!/bin/bash
# Deploys the kernels in build/ into a consumer checked out on its main: replaces its vendored directory with them,
# builds the consumer as its own CI does, so that a broken kernel never reaches its main, then commits them with the
# FlexKernels commits they pass on and pushes. Run from FlexKernels checked out with full history, as CI and the local
# rehearsal do. Usage: ci/deploy.sh <consumer-dir> <cuda|wgsl> <vendored-path>
set -euo pipefail
consumer=$1 source=$2 vendored=$3
sha=$(git rev-parse HEAD)
old=$(cat "$consumer/$vendored/VERSION")
git -C "$consumer" rm -rq "$vendored"
mkdir -p "$consumer/$vendored"
cp build/"$source"/* "$consumer/$vendored"
echo "$sha" > "$consumer/$vendored/VERSION"
case $source in
    cuda) make -C "$consumer" ;;
    wgsl) (cd "$consumer" && bash ./build-script) ;;
esac
git -C "$consumer" add "$vendored"
git -C "$consumer" diff --cached --quiet && exit 0
git -C "$consumer" config user.name "Bendik Arbogast"
git -C "$consumer" config user.email "arbobendik@gmail.com"
git -C "$consumer" commit -q -m "chore(flexkernels): update kernels to ${sha::7}" -m "$(git log --format='%h %s' "$old..$sha")"
git -C "$consumer" push origin HEAD:main || { git -C "$consumer" pull --rebase origin main && git -C "$consumer" push origin HEAD:main; }
