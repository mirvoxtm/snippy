#!/bin/sh
set -e
dir=$(dirname "$(readlink -f "$0")")
milk_src=${MILK_SRC:-}
if [ -z "$milk_src" ]; then
    if [ -f "$dir/../milk/src/milk/main.odin" ]; then
        milk_src="$dir/../milk/src"
    else
        recorded=$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/milk/location" 2>/dev/null || true)
        [ -n "$recorded" ] && milk_src="$recorded/src"
    fi
fi
[ -n "$milk_src" ] && [ -d "$milk_src/tx" ] || { echo "snippy: milk's sources not found (clone milk next to snippy or set MILK_SRC)" >&2; exit 1; }
mkdir -p "$dir/bin"
odin build "$dir/src" -collection:milk="$milk_src" -out:"$dir/bin/snippy" -o:speed -vet ${SNIPPY_ODIN_FLAGS:-}
echo "built $dir/bin/snippy"
