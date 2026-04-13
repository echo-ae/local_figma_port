#!/usr/bin/env bash

lfp_default_state_root() {
  case "$(uname -s)" in
    Darwin)
      printf '%s' "${HOME}/Library/Application Support/LocalFigmaPort"
      ;;
    *)
      printf '%s' "${HOME}/.local/share/local-figma-port"
      ;;
  esac
}

lfp_data_dir() {
  local state_root="$1"
  printf '%s/data' "$state_root"
}

lfp_sqlite_path() {
  local state_root="$1"
  printf '%s/design_store.sqlite' "$(lfp_data_dir "$state_root")"
}

lfp_run_dir() {
  local state_root="$1"
  printf '%s/run' "$state_root"
}

lfp_log_dir() {
  local state_root="$1"
  printf '%s/logs' "$state_root"
}

lfp_pid_file() {
  local state_root="$1"
  printf '%s/mcp-server.pid' "$(lfp_run_dir "$state_root")"
}

lfp_log_file() {
  local state_root="$1"
  printf '%s/mcp-server.log' "$(lfp_log_dir "$state_root")"
}

lfp_claude_desktop_dir() {
  local state_root="$1"
  printf '%s/claude-desktop' "$state_root"
}

lfp_claude_desktop_bundle_path() {
  local state_root="$1"
  printf '%s/local-figma-port.mcpb' "$(lfp_claude_desktop_dir "$state_root")"
}
