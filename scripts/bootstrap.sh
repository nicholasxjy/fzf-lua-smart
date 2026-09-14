#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .deps
checkout() {
  name=$1 url=$2 ref=$3
  if [ ! -d ".deps/$name/.git" ]; then git clone --filter=blob:none "$url" ".deps/$name"; fi
  git -C ".deps/$name" fetch origin "$ref"
  git -C ".deps/$name" checkout --detach FETCH_HEAD
}
checkout snacks.nvim https://github.com/folke/snacks.nvim.git 882c996cf28183f4d63640de0b4c02ec886d01f2
checkout fzf-lua https://github.com/ibhagwan/fzf-lua.git "${FZF_LUA_REF:-05e44d38de0a79c11fba5f7bf8138791b1dbdd1e}"
