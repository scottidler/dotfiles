#!/bin/bash
# Creates a 4x3 grid (4 columns, 3 rows = 12 panes)

tmux new-window

# Create 3 rows
tmux split-window -v
tmux split-window -v
tmux select-layout even-vertical

# Split each row into 4 columns
for pane in 0 4 8; do
    tmux select-pane -t $pane
    tmux split-window -h
    tmux split-window -h -t $pane
    tmux split-window -h -t $((pane + 2))
done

tmux select-pane -t 0
