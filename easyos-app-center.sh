#!/bin/sh
# EasyOS App Center 0.1 — GTKdialog, APT and Flatpak catalogues.
# Copyright 2026 pp4mnk contributors. SPDX-License-Identifier: MIT
set -u
# Run `sh easyos-app-center.sh --diagnose` to check the required components.
if [ "${1:-}" = --diagnose ]; then
  printf 'EasyOS App Center 0.2 diagnostics\n'
  for c in gtkdialog apt-cache apt flatpak rxvt xterm pkg_chooser.sh sfsget flapi appi; do
    if command -v "$c" >/dev/null 2>&1; then printf '%-18s %s\n' "$c" "$(command -v "$c")"
    else printf '%-18s %s\n' "$c" 'not found'; fi
  done
  printf 'User ID: %s\nDISPLAY: %s\n' "$(id -u)" "${DISPLAY:-unset}"
  exit 0
fi
export LC_ALL="${LC_ALL:-C.UTF-8}"
fail() {
  printf '%s\n' "$1" >&2
  if command -v Xdialog >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
    Xdialog --title 'EasyOS App Center' --msgbox "$1" 9 64 2>/dev/null || :
  fi
  exit 1
}
if ! command -v gtkdialog >/dev/null 2>&1; then
  fail 'gtkdialog is missing. Run: sh easyos-app-center.sh --diagnose'
fi
if [ -z "${DISPLAY:-}" ]; then fail 'No graphical desktop detected (DISPLAY is unset).'; fi
if [ "$(id -u)" -ne 0 ]; then
  fail 'Run this application as root in the main EasyOS desktop.'
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/easy-app-center.XXXXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT HUP INT TERM
chmod 700 "$work"
script=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
export EASY_APP_CENTER_SCRIPT="$script" EASY_APP_CENTER_WORK="$work"
xml_escape() { printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
valid_id() { case "$1" in ''|*[!A-Za-z0-9.+_:-]*) return 1;; esac; }
notify_user() {
  local_msg=$(xml_escape "$1")
  export EASY_MSG="<window title=\"EasyOS App Center\"><vbox><text><label>$(printf '%s' "$local_msg")</label></text><button ok></button></vbox></window>"
  gtkdialog --center --program=EASY_MSG >/dev/null
}
terminal_run() {
  if command -v rxvt >/dev/null 2>&1; then rxvt -hold -e sh -c '"$@"; result=$?; printf "\\nExit status: %s. Press Enter to close." "$result"; read -r unused' sh "$@" &
  elif command -v xterm >/dev/null 2>&1; then xterm -hold -e sh -c '"$@"; result=$?; printf "\\nExit status: %s. Press Enter to close." "$result"; read -r unused' sh "$@" &
  else notify_user 'A terminal (rxvt or xterm) is required to display the installation.'; fi
}
open_manager() {
  case "$1" in
    pkg) for c in pkg_chooser.sh pkg_chooser; do if command -v "$c" >/dev/null 2>&1; then "$c" & return; fi; done
         if [ -x /usr/local/petget/pkg_chooser.sh ]; then /usr/local/petget/pkg_chooser.sh & return; fi;;
    flat) if command -v flapi >/dev/null 2>&1; then flapi & return; fi;;
    sfs) for c in sfsget SFSget; do if command -v "$c" >/dev/null 2>&1; then "$c" & return; fi; done;;
    appi) if command -v appi >/dev/null 2>&1; then appi & return; fi;;
  esac
  notify_user "That manager is not available on this EasyOS installation."
}
# Each row is source | application identifier | short description. Tabs/newlines are removed.
make_catalogue() {
  : > "$work/catalogue"
  if command -v apt-cache >/dev/null 2>&1; then
    apt-cache search --names-only . 2>/dev/null | awk -F ' - ' 'NF >= 2 && $1 ~ /^[a-zA-Z0-9][a-zA-Z0-9+._-]*$/ { d=$2; for(i=3;i<=NF;i++)d=d " - " $i; gsub(/\t|\r/," ",d); print "APT\t" $1 "\t" d }' >> "$work/catalogue"
  fi
  if command -v flatpak >/dev/null 2>&1; then
    # Remote app catalogue only; installed runtimes are excluded.
    flatpak remotes --columns=name 2>/dev/null | while IFS= read -r remote; do
      case "$remote" in ''|*[!A-Za-z0-9._-]*) continue;; esac
      flatpak remote-ls --app --columns=application,name "$remote" 2>/dev/null |
        awk -F '\t' -v rem="$remote" 'NF>=2 && $1 ~ /^[A-Za-z0-9._-]+$/ {gsub(/\t|\r/," ",$2); print "Flatpak (" rem ")\t" $1 "\t" $2}' >> "$work/catalogue"
    done
  fi
  sort -u "$work/catalogue" -o "$work/catalogue"
}
render_rows() {
  awk -F '\t' -v q="$1" 'BEGIN {q=tolower(q); count=0} q=="" || index(tolower($2 " " $3),q) {if(++count>250)exit; print $1 "|" $2 "|" $3}' "$work/catalogue" |
  while IFS='|' read -r source identifier description; do
    printf '<item>%s|%s|%s</item>\n' "$(xml_escape "$source")" "$(xml_escape "$identifier")" "$(xml_escape "$description")"
  done
}
install_selected() {
  ident=$1
  # The selected identifier is resolved from the original catalogue; no GUI data is evaluated.
  [ -n "$ident" ] || { notify_user 'Select an application first.'; return; }
  source=$(awk -F '\t' -v p="$ident" '$2==p {print $1; exit}' "$work/catalogue")
  if ! awk -F '\t' -v s="$source" -v p="$ident" '$1==s && $2==p {found=1} END {exit !found}' "$work/catalogue"; then
    notify_user 'This application is not in the current catalogue.'; return
  fi
  valid_id "$ident" || { notify_user 'Invalid application identifier.'; return; }
  case "$source" in
    APT)
      if command -v apt >/dev/null 2>&1; then terminal_run apt install -- "$ident"
      else open_manager pkg; fi;;
    'Flatpak ('*')')
      remote=${source#'Flatpak ('}; remote=${remote%')'}
      valid_id "$remote" || { notify_user 'Invalid Flatpak remote.'; return; }
      terminal_run flatpak install --user "$remote" "$ident";;
  esac
}
# Each launch refreshes the catalogue. The search refresh is deliberately local and fast.
make_catalogue
query=''
while :; do
  rows=$(render_rows "$query")
  export EASY_CENTER_GUI="<window title=\"EasyOS App Center 0.1\" default-width=\"850\" default-height=\"540\"><vbox>
  <text><label>Search applications available from APT and configured Flatpak remotes</label></text>
  <hbox><entry><variable>SEARCH</variable></entry><button><label>Search</label><action type=\"exit\">SEARCH_ACTION</action></button></hbox>
  <tree exported_column=\"1\"><label>Source|Application|Description</label><variable>CHOSEN</variable><height>380</height>$rows</tree>
  <hbox><button><label>Install selected</label><action type=\"exit\">INSTALL_ACTION</action></button>
  <button><label>PKGget</label><action type=\"exit\">PKG_ACTION</action></button>
  <button><label>Flapi</label><action type=\"exit\">FLAT_ACTION</action></button>
  <button><label>SFSget</label><action type=\"exit\">SFS_ACTION</action></button>
  <button><label>Appi</label><action type=\"exit\">APPI_ACTION</action></button>
  <button><label>Close</label><action type=\"exit\">CLOSE_ACTION</action></button></hbox>
  <text><label>First 250 matches shown. Installation asks for confirmation in a terminal.</label></text>
  </vbox></window>"
  result=$(gtkdialog --center --program=EASY_CENTER_GUI 2>"$work/gtkdialog-error")
  gui_status=$?
  if [ "$gui_status" -ne 0 ]; then
    printf 'gtkdialog failed with status %s:\n' "$gui_status" >&2
    cat "$work/gtkdialog-error" >&2
    fail "Interface error. Run this file from a terminal to read the details."
  fi
  action=$(printf '%s\n' "$result" | sed -n 's/^EXIT="\(.*\)"$/\1/p' | tail -n 1)
  new_query=$(printf '%s\n' "$result" | sed -n 's/^SEARCH="\(.*\)"$/\1/p' | tail -n 1)
  # GTKdialog quotes values. Convert only escaped quotes, no eval.
  query=$(printf '%s' "$new_query" | sed 's/\\"/"/g' | cut -c 1-100)
  case "$action" in
    SEARCH_ACTION) :;;
    INSTALL_ACTION) chosen=$(printf '%s\n' "$result" | sed -n 's/^CHOSEN="\(.*\)"$/\1/p' | tail -n 1); install_selected "$chosen";;
    PKG_ACTION) open_manager pkg;; FLAT_ACTION) open_manager flat;; SFS_ACTION) open_manager sfs;; APPI_ACTION) open_manager appi;;
    *) break;;
  esac
done
