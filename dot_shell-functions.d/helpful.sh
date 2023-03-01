#!/usr/bin/zsh

if [ -n "$DEBUG" ]; then
    PS4=':${LINENO}+'
    set -x
fi

VIM=$(print -r -- =vim)
function vim() {
    ARGS=("$@")

    VIM_MIN="${VIM_MIN:-2}"
    VIM_MAX="${VIM_MAX:-3}"

    for arg in "${ARGS[@]}"; do
        if [[ "$arg" == "-"* ]]; then
            eval $VIM "${ARGS[@]}"
        fi
    done

    case ${#ARGS[@]} in
        [0-1])                  eval $VIM    "${ARGS[@]}";;
        [$VIM_MIN-$VIM_MAX])    eval $VIM -O "${ARGS[@]}";;
        *)                      eval $VIM -o "${ARGS[@]}";;
    esac
}

# listppa Script to get all the PPA installed on a system ready to share for reininstall
function ls-ppas() {
    for APT in `find /etc/apt/ -name \*.list`; do
        grep -o "^deb http://ppa.launchpad.net/[a-z0-9\-]\+/[a-z0-9\-]\+" $APT | while read ENTRY ; do
            USER=`echo $ENTRY | cut -d/ -f4`
            PPA=`echo $ENTRY | cut -d/ -f5`
            echo ppa:$USER/$PPA
        done
    done
}

function vim755() {
    vim "$@"
    chmod 755 "$@"
}

function touch755() {
    touch "$@"
    chmod 755 "$@"
}

function follow() {
    FILE="$1"
    printf $FILE
    while true; do
        FILE=`readlink $FILE`
        if [ -z "$FILE" ]; then
            break
        fi
        printf " -> $FILE"
    done
    echo
}

function dbsl() {
    DIR="${1:-`pwd`}"
    RESULTS=`find -L $DIR -maxdepth 1 -type l`
    if [ -n "$RESULTS" ]; then
        echo "[d]elete [b]roken [s]ymbolic [l]inks"
        echo "$RESULTS"
        echo "-> /dev/null"
        find -L $DIR -maxdepth 1 -type l -delete
    fi
}

function every() {
    INTERVAL="$1"; shift
    COMMAND="$@"
    while true; do
        echo "$(date) $COMMAND"
        eval "$COMMAND"
        sleep $INTERVAL
    done
}

function mkfiles() {
    NUM="$1"
    DIR="${2:-.}"

    echo "NUM=$NUM"
    echo "DIR=$DIR"

    if ((NUM > 0)); then
        mkdir -p $DIR
        for i in `seq 1 $NUM`; do
            mktemp -p $DIR
        done
    else
        echo "NUM [DIR]"
        return 1
    fi
}

function ls-docker-tags() {
    if [ "$#" -ne 1 ]; then
        echo "supply image name"
        return 1
    fi
    wget -q https://registry.hub.docker.com/v1/repositories/$1/tags -O -  | sed -e 's/[][]//g' -e 's/"//g' -e 's/ //g' | tr '}' '\n'  | awk -F: '{print $3}'

}

function dhclient-restart() {
    ETHDEV=${1:-$(ip route get 1.1.1.1 | grep -Po '(?<=dev\s)\w+' | cut -f1 -d ' ')}
    sudo dhclient -r -v $ETHDEV && sudo rm /var/lib/dhcp/dhclient.*; sudo dhclient -v $ETHDEV
}

function pmu() {
    if hash apt-get 2> /dev/null; then
        echo "updating apt packages..."
        sudo apt-get update
        sudo apt-get upgrade -y --allow-unauthenticated --allow-downgrades
        sudo apt-get dist-upgrade -y
        sudo apt-get autoremove -y
    fi
    if hash dnf 2> /dev/null; then
        echo "updating dnf packages..."
        sudo dnf upgrade -y
    elif hash yum 2> /dev/null; then
        echo "updating yum packages..."
        sudo yum upgrade -y
    fi
}

function pu() {
    if hash pipupgrade 2> /dev/null; then
        echo "updating pip3 packages..."
        pipupgrade -y --pip-path /usr/local/bin/pip3
    fi
}

function pu2() {
    sudo -H python3 -m pip install --root-user-action=ignore -U pip
    sudo -H python3 -m pip list --outdated --format=freeze \
        | \grep --color=auto -v '^\-3' \
        | cut -d= -f1 \
        | grep -vxFf ~/.distutils.pkgs \
        | xargs -n1 sudo -H python3 -m pip install --root-user-action=ignore -U
}

function pu3() {
    sudo -H python3 -m pip install --root-user-action=ignore -U pip
    sudo -H python3 -m pip list --outdated \
        | grep --color=auto -v '^\-3' \
        | cut -d' ' -f1 \
        | tail -n +3 \
        | grep --color=auto -vxFf ~/.distutils.pkgs \
        | xargs -n1 sudo -H python3 -m pip install --root-user-action=ignore -U
}

function update() {
    echo
    pmu
    echo
    pu3
}

function reboot() {
    kill-chrome
    kill-firefox
    sudo systemctl reboot
}

function replace() {
    FIND="$1"
    REPL="$2"
    DIR="${3-.}"
    if [ -z "$FIND" ]; then
        echo "replace FIND [REPL] [DIR]"
        return 1
    fi
    find "$DIR" -path ./.git -prune -o -type f -exec sed -i "s/$FIND/$REPL/g" {} \;
}

function ovpn() {
    ARGS="$@"
    sudo pkill openvpn
    find ~/.openvpn/ -name *.ovpn |
    while read FILEPATH; do
        DIR=`dirname $FILEPATH`
        CFG=`basename $FILEPATH`
        CMD="(cd $DIR && sudo openvpn --config $CFG $ARGS) &"
        echo "$CMD"
        eval "$CMD"
    done
}

function upsearch() {
    FILE="$1"
    DIR="$PWD"
    while [[ "$DIR" != '/' ]]; do
        if [[ -e "$DIR/$FILE" ]]; then
            echo "$DIR"
            return
        else
            DIR=`dirname $DIR`
        fi
    done
    echo "$PWD"
    return
}

function doit() {
    DOIT="$(print -r -- =doit)"
    if [[ "$1" =~ ^(auto|clean|dumpdb|forget|help|ignore|info|list|reset-dep|run|strace|tabcompletion)$ ]]; then
        CMD=( $DOIT $@ )
    else
        NPROC=$(nproc)
        ONE_AND_A_HALF=$(($NPROC + $NPROC/2))
        DOIT_NUM_PROCESS=${DOIT_NUM_PROCESS:-$ONE_AND_A_HALF}
        CMD=( time -p $DOIT -n $DOIT_NUM_PROCESS $@ )
    fi
    (cd "`upsearch dodo.py`" && "${CMD[@]}")
}

function toplevel() {
    [ -d "$1" ] && echo "$1" || echo "$(dirname "$1")"
}

function mv-replace() {
    FILE=$1
    REPL=${2:-'-'}
    mv $FILE ${FILE// /$REPL}
}

function delete-branch() {
    for branch in "$@"; do
        echo "deleting $branch"
        git push origin :"$branch"
        git branch -D "$branch"
    done
    git prune
}
