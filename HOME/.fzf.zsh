# Setup fzf
# ---------
if [[ ! "$PATH" == */home/saidler/repos/junegunn/fzf/bin* ]]; then
  PATH="${PATH:+${PATH}:}/home/saidler/repos/junegunn/fzf/bin"
fi

source <(fzf --zsh)
