#!/usr/bin/env bash
# ============================================================================ #
# update_submodules.sh                                                          #
#                                                                              #
# Recursively bring EVERY submodule (at any depth) to the latest commit on its  #
# remote's HEAD branch — auto-detected, no hardcoded paths.                     #
#                                                                              #
# It also REPAIRS "orphan" gitlinks: a path recorded as a submodule            #
# (tree mode 160000) in a repo's HEAD but missing from that repo's .gitmodules  #
# — an upstream packaging bug (e.g. libft commits srcs/memory/ft_malloc without #
# declaring it). For each orphan the URL is inferred as a sibling of the parent #
# repo's `origin` remote (same host/org, basename + .git), verified with        #
# `git ls-remote`, registered in .gitmodules, then fetched.                     #
#                                                                              #
# Why per-level (not a single `git submodule update --remote --recursive`):     #
# a recursive pass aborts (exit 128) the instant it meets an unregistered deep  #
# gitlink, leaving siblings un-updated. We walk level by level so one broken    #
# link can be repaired in place instead of poisoning the whole tree.            #
# ============================================================================ #
set -u

# Colours (match the Makefile; honour NO_COLOR and non-TTY output).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	G='\033[32m'; Y='\033[33m'; B='\033[34m'; R='\033[31m'; Z='\033[0m'
else
	G=''; Y=''; B=''; R=''; Z=''
fi
say() { printf "%b\n" "$*"; }

# Print "<sha> <path>" for every gitlink (submodule) in repo $1's HEAD tree.
gitlinks() {
	git -C "$1" ls-tree -r HEAD 2>/dev/null \
		| awk '$1=="160000"{ sha=$3; $1=$2=$3=""; sub(/^[ \t]+/,""); print sha" "$0 }'
}

# Print the paths of every submodule registered in repo $1's .gitmodules.
registered_paths() {
	git -C "$1" config -f "$1/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
		| awk '{ $1=""; sub(/^[ \t]+/,""); print }'
}

# True if path $2 is already registered in repo $1's .gitmodules.
is_registered() {
	registered_paths "$1" | grep -qxF "$2"
}

# Infer a sibling remote URL for submodule path $2 from parent repo $1's origin:
# same host/org, repo name = basename of the submodule path.
infer_url() {
	local origin
	origin=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
	[ -n "$origin" ] || return 1
	origin=${origin%.git}
	printf '%s/%s.git\n' "${origin%/*}" "$(basename "$2")"
}

# Register + fetch any orphan gitlinks found in repo $1.
repair_orphans() {
	local repo="$1" sha path url
	while read -r sha path; do
		[ -n "$path" ] || continue
		is_registered "$repo" "$path" && continue
		say "${Y}⚠${Z}  Orphan gitlink in ${repo#$ROOT/}: ${path} (missing from .gitmodules)"
		url=$(infer_url "$repo" "$path") || { say "${R}✗${Z} Cannot infer URL for ${path}"; continue; }
		if ! git ls-remote "$url" >/dev/null 2>&1; then
			say "${R}✗${Z} Inferred URL not reachable: ${url} — skipping ${path}"
			continue
		fi
		git -C "$repo" config -f "$repo/.gitmodules" "submodule.${path}.path" "$path"
		git -C "$repo" config -f "$repo/.gitmodules" "submodule.${path}.url"  "$url"
		git -C "$repo" submodule sync -- "$path" >/dev/null 2>&1 || true
		if git -C "$repo" submodule update --init --remote --force -- "$path" >/dev/null 2>&1 \
			|| git -C "$repo" submodule update --init --force -- "$path" >/dev/null 2>&1; then
			say "${G}✓${Z} Repaired & registered: ${path} -> ${url}"
		else
			say "${R}✗${Z} Registered but failed to fetch: ${path} -> ${url}"
		fi
	done < <(gitlinks "$repo")
}

# Update repo $1's direct children to their remote tip, repair orphans, then recurse.
process_repo() {
	local repo="$1" path
	git -C "$repo" submodule sync >/dev/null 2>&1 || true
	# Non-recursive on purpose: advances every *registered* direct child to its remote
	# tip and never aborts on an unregistered deep gitlink (handled by repair_orphans).
	git -C "$repo" submodule update --init --remote --force >/dev/null 2>&1 \
		|| git -C "$repo" submodule update --init --force >/dev/null 2>&1 || true
	repair_orphans "$repo"
	while read -r path; do
		[ -n "$path" ] || continue
		[ -e "$repo/$path/.git" ] && process_repo "$repo/$path"
	done < <(registered_paths "$repo")
}

ROOT=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) \
	|| { say "${R}✗${Z} Not inside a git repository"; exit 1; }

say "${B}▶${Z} Updating all submodules to latest upstream (recursive, with repair)..."
process_repo "$ROOT"

say "${B}▶${Z} Submodule tree:"
git -C "$ROOT" submodule status --recursive 2>/dev/null || true
