#!/usr/bin/env hellish
# tools/launcher_probe.sh -- can the shell running this file interpret
# born2root's scripts? Run by the Makefile as `<candidate> tools/launcher_probe.sh`
# for each candidate launcher, with no shell in between (make execs a command
# line without metacharacters directly). Prints `B2R_SH=<absolute path of the
# shell running this>` when the answer is yes, and nothing otherwise, so that a
# candidate that is not a shell at all (make itself, python, an editor) cannot
# leave anything on stdout that could be mistaken for a shell.
#
# The tests are the scripts' bash-isms -- arrays, local, BASH_SOURCE -- and
# BASH_VERSION, which zsh lacks (zsh would pass the rest and then abort on the
# first unmatched glob). dash stops at the first line: `exit` before it parses
# anything it could not.
[ -n "${BASH_VERSION:-}" ] || exit 0
eval 'a=(1 2); f() { local x=0; }; f; : "${BASH_SOURCE[0]:-x}"' 2>/dev/null || exit 0
me=$(readlink /proc/$$/exe 2>/dev/null)
[ -n "$me" ] && [ -x "$me" ] || exit 0
printf 'B2R_SH=%s\n' "$me"
