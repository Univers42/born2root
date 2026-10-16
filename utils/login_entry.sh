#!/usr/bin/env hellish
# login_entry.sh — an XDG autostart entry that runs one command at every
# desktop login, once the files it names exist. Sourced, never run.
#
# WHY IT WAITS
#   A 42 seat restores the home after GNOME has read ~/.config/autostart: on
#   2026-10-16 the seat-tailnet entry fired at 14:15:40 and died on
#   "seat_tailnet.sh: No such file or directory", while ~/born2root was created
#   at 14:16:25. So the command runs inside sh -c behind an until-loop over
#   every absolute path among its words (the shell, the script; not the
#   NAME=/path assignments, whose files the command itself checks). GNOME
#   splits Exec like a shell (g_shell_parse_argv), so the single quotes hold.
#
# Caveat: the wait gives up after 20 minutes (timeout 1200, exit 124); a home
# restored later than that runs nothing until the next login or a manual run.
# A word with a space, a quote or a % cannot be carried as written and is
# refused: GNOME would split it or expand the %.

# login_entry_exec WORD...: the Exec= value that waits, then runs the words.
# Words, not one string: hellish does not word-split an unquoted expansion.
login_entry_exec() {
    local word waits=""
    for word in "$@"; do
        case "$word" in
        /*) waits="${waits:+$waits && }[ -e $word ]" ;;
        esac
    done
    printf "timeout 1200 sh -c 'until %s; do sleep 2; done; exec %s'" "${waits:-true}" "$*"
}

# login_entry_write ENTRY NAME COMMENT WORD...: write ENTRY (a .desktop path)
# unless it already says exactly that. 1, with the reason on stderr, on a word
# the Exec line cannot carry or a file that cannot be written.
login_entry_write() {
    local entry="$1" name="$2" comment="$3" word tmp
    shift 3
    for word in "$@"; do
        case "$word" in
        *[[:space:]\'\"%]*)
            printf "'%s' holds a space, a quote or a %%: a desktop entry's Exec cannot carry it as written; move it or rename it\n" "$word" >&2
            return 1
            ;;
        esac
    done
    mkdir -p "$(dirname "$entry")" || return 1
    tmp=$(mktemp "$(dirname "$entry")/.login-entry.XXXXXX") || return 1
    printf '%s\n' '[Desktop Entry]' 'Type=Application' "Name=$name" "Comment=$comment" \
        "Exec=$(login_entry_exec "$@")" 'Terminal=false' 'NoDisplay=true' \
        'X-GNOME-Autostart-enabled=true' >"$tmp"
    if cmp -s "$tmp" "$entry"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$entry"
    fi
}
