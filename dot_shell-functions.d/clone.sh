#!/usr/bin/zsh

if [ -n "$DEBUG" ]; then
    PS4=':${LINENO}+'
    set -x
fi

function clone() {
    if [[ "$@" == *"-h"* ]] || [[ "$@" == *"--help"* ]]; then
        eval ~/bin/clone "$@"
    else
        cd $(~/bin/clone $1)
    fi
}

function rm-tag() {
    TAG="$1"
    git tag -d $TAG; git push origin :$TAG
}

function github-url() {
    FILENAME=$1
    REPOPATH=$(git rev-parse --show-toplevel)
    RELPATH=$(realpath --relative-to="$REPOPATH" "$PWD")
    FILEPATH="$RELPATH/$FILENAME"
    FILEPATH="${FILEPATH#*./}"
    BRANCH=$(git symbolic-ref --short HEAD)
    REMOTE=$(git config --get remote.origin.url)
    REPONAME=$(python3 <<-EOF
from urllib.parse import urlparse
pr = urlparse("$REMOTE")
print(pr.path)
EOF
)
    TYPE=tree
    [ -n "$FILENAME" ] && [ -f "$FILENAME" ] && TYPE=blob
    echo "https://github.com$REPONAME/$TYPE/$BRANCH/$FILEPATH"
}
