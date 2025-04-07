#!/bin/bash

# Variables
session_name="my_parallel_session"
static_dir="/path/to/your/static/files" # Replace with your actual path

# Function to check if a tmux session exists
tmux_session_exists() {
  tmux has-session -t "$1" 2>/dev/null
}

# Kill existing session if it exists
if tmux_session_exists "$session_name"; then
  echo "Killing existing tmux session: $session_name"
  tmux kill-session -t "$session_name"
fi

# Create a new detached tmux session
tmux new-session -d -s "$session_name"

# Configure windows with named panes
tmux rename-window -t "$session_name":0 "http-server"
tmux send-keys -t "$session_name":0 "npx http-server -p 8010" Enter

tmux new-window -t "$session_name":1 -n "cloudflared"
tmux send-keys -t "$session_name":1 "cloudflared tunnel run 903806fe-8c15-4ab1-b2cf-c6cac88b1066" Enter

tmux new-window -t "$session_name":2 -n "craftos"
tmux send-keys -t "$session_name":2 "craftos --script auto_update.lua --args test.lua --cli --mount /=/Users/earv1/Documents/git/computercraft" Enter

# Set default window
tmux select-window -t "$session_name":0

echo "Tmux session '$session_name' created with parallel processes."
echo "Attaching to session..."

# Auto-attach to the session
tmux attach -t "$session_name"