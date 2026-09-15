#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT INT TERM
export XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" XDG_CONFIG_HOME="$root/config"
export FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE=''
export NO_COLOR=''
nvim --headless -u tests/minimal.lua -l tests/no_snacks.lua
nvim --headless -u tests/minimal.lua -l tests/run.lua
