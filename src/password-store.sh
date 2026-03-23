#!/usr/bin/env bash

# Copyright (C) 2012 - 2018 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
# This file is licensed under the GPLv2+. Please see COPYING for more information.

umask "${PASSWORD_STORE_UMASK:-077}"
set -o pipefail

GPG_OPTS=( $PASSWORD_STORE_GPG_OPTS "--quiet" "--yes" "--compress-algo=none" "--no-encrypt-to" )
GPG="gpg"
export GPG_TTY="${GPG_TTY:-$(tty 2>/dev/null)}"
command -v gpg2 &>/dev/null && GPG="gpg2"
[[ -n $GPG_AGENT_INFO || $GPG == "gpg2" ]] && GPG_OPTS+=( "--batch" "--use-agent" )

PREFIX="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
X_SELECTION="${PASSWORD_STORE_X_SELECTION:-clipboard}"
CLIP_TIME="${PASSWORD_STORE_CLIP_TIME:-45}"
GENERATED_LENGTH="${PASSWORD_STORE_GENERATED_LENGTH:-25}"
CHARACTER_SET="${PASSWORD_STORE_CHARACTER_SET:-[:punct:][:alnum:]}"
CHARACTER_SET_NO_SYMBOLS="${PASSWORD_STORE_CHARACTER_SET_NO_SYMBOLS:-[:alnum:]}"





GPG_ID_FILE="$PREFIX/.gpg-id"
[[ -f "$GPG_ID_FILE" ]] || die "Error: Store not initialized. Run 'pass init <gpg-id>'."
GPG_RECIPIENT=$(head -n 1 "$GPG_ID_FILE")






unset GIT_DIR GIT_WORK_TREE GIT_NAMESPACE GIT_INDEX_FILE GIT_INDEX_VERSION GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
export GIT_CEILING_DIRECTORIES="$PREFIX/.."

#
# BEGIN helper functions
#

set_git() {
    if [[ $(git -C "$PREFIX" rev-parse --is-inside-work-tree 2>/dev/null) == true ]]; then
        INNER_GIT_DIR="$PREFIX"
    else
        INNER_GIT_DIR=""
    fi
}
git_add_file() {
	[[ -n $INNER_GIT_DIR ]] || return
	git -C "$INNER_GIT_DIR" add "$1" || return
	[[ -n $(git -C "$INNER_GIT_DIR" status --porcelain "$1") ]] || return
	git_commit "$2"
}
git_commit() {
	local sign=""
	[[ -n $INNER_GIT_DIR ]] || return
	[[ $(git -C "$INNER_GIT_DIR" config --bool --get pass.signcommits) == "true" ]] && sign="-S"
	git -C "$INNER_GIT_DIR" commit $sign -m "$1"
}
yesno() {
	[[ -t 0 ]] || return 0
	local response
	read -r -p "$1 [y/N] " response
	[[ $response == [yY] ]] || exit 1
}
die() {
	echo "$@" >&2
	exit 1
}
check_sneaky_paths() {
	local path
	for path in "$@"; do
		[[ $path =~ /\.\.$ || $path =~ ^\.\./ || $path =~ /\.\./ || $path =~ ^\.\.$ ]] && die "Error: You've attempted to pass a sneaky path to pass. Go home."
	done
}

#
# END helper functions
#

#
# BEGIN platform definable
#

clip() {
	if [[ -n $WAYLAND_DISPLAY ]] && command -v wl-copy &> /dev/null; then
		local copy_cmd=( wl-copy )
		local paste_cmd=( wl-paste -n )
		if [[ $X_SELECTION == primary ]]; then
			copy_cmd+=( --primary )
			paste_cmd+=( --primary )
		fi
		local display_name="$WAYLAND_DISPLAY"
	elif [[ -n $DISPLAY ]] && command -v xclip &> /dev/null; then
		local copy_cmd=( xclip -selection "$X_SELECTION" )
		local paste_cmd=( xclip -o -selection "$X_SELECTION" )
		local display_name="$DISPLAY"
	else
		die "Error: No X11 or Wayland display and clipper detected"
	fi
	local sleep_argv0="password store sleep on display $display_name"

	# This base64 business is because bash cannot store binary data in a shell
	# variable. Specifically, it cannot store nulls nor (non-trivally) store
	# trailing new lines.
	pkill -f "^$sleep_argv0" 2>/dev/null && sleep 0.5
	local before="$("${paste_cmd[@]}" 2>/dev/null | $BASE64)"
	echo -n "$1" | "${copy_cmd[@]}" || die "Error: Could not copy data to the clipboard"
	(
		( exec -a "$sleep_argv0" bash <<<"trap 'kill %1' TERM; sleep '$CLIP_TIME' & wait" )
		local now="$("${paste_cmd[@]}" | $BASE64)"
		[[ $now != $(echo -n "$1" | $BASE64) ]] && before="$now"

		# It might be nice to programatically check to see if klipper exists,
		# as well as checking for other common clipboard managers. But for now,
		# this works fine -- if qdbus isn't there or if klipper isn't running,
		# this essentially becomes a no-op.
		#
		# Clipboard managers frequently write their history out in plaintext,
		# so we axe it here:
		qdbus org.kde.klipper /klipper org.kde.klipper.klipper.clearClipboardHistory &>/dev/null

		echo "$before" | $BASE64 -d | "${copy_cmd[@]}"
	) >/dev/null 2>&1 & disown
	echo "Copied $2 to clipboard. Will clear in $CLIP_TIME seconds."
}


tmpdir() {
	[[ -n $SECURE_TMPDIR ]] && return
	local warn=1
	[[ $1 == "nowarn" ]] && warn=0
	local template="$PROGRAM.XXXXXXXXXXXXX"
	if [[ -d /dev/shm && -w /dev/shm && -x /dev/shm ]]; then
		SECURE_TMPDIR="$(mktemp -d "/dev/shm/$template")"
		remove_tmpfile() {
			rm -rf "$SECURE_TMPDIR"
		}
		trap remove_tmpfile EXIT
	else
		[[ $warn -eq 1 ]] && yesno "$(cat <<-_EOF
		Your system does not have /dev/shm, which means that it may
		be difficult to entirely erase the temporary non-encrypted
		password file after editing.

		Are you sure you would like to continue?
		_EOF
		)"
		SECURE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/$template")"
		shred_tmpfile() {
			find "$SECURE_TMPDIR" -type f -exec $SHRED {} +
			rm -rf "$SECURE_TMPDIR"
		}
		trap shred_tmpfile EXIT
	fi

}
GETOPT="getopt"
SHRED="shred -f -z"
BASE64="base64"


#
# END platform definable
#


#
# BEGIN subcommand functions
#

cmd_version() {
	cat <<-_EOF
	============================================
	= pass: the standard unix password manager =
	=                                          =
	=                  v1.7.4                  =
	=                                          =
	=             Jason A. Donenfeld           =
	=               Jason@zx2c4.com            =
	=                                          =
	=      http://www.passwordstore.org/       =
	============================================
	_EOF
}

cmd_usage() {
	cmd_version
	echo
	cat <<-_EOF
	Usage:
	    $PROGRAM init [--path=subfolder,-p subfolder] gpg-id...
	        Initialize new password storage and use gpg-id for encryption.
	        Selectively reencrypt existing passwords using new gpg-id.
	    $PROGRAM [ls] [subfolder]
	        List passwords.
	    $PROGRAM find pass-names...
	    	List passwords that match pass-names.
	    $PROGRAM [show] [--clip[=line-number],-c[line-number]] pass-name
	        Show existing password and optionally put it on the clipboard.
	        If put on the clipboard, it will be cleared in $CLIP_TIME seconds.
	    $PROGRAM grep [GREPOPTIONS] search-string
	        Search for password files containing search-string when decrypted.
	    $PROGRAM insert [--echo,-e | --multiline,-m] [--force,-f] pass-name
	        Insert new password. Optionally, echo the password back to the console
	        during entry. Or, optionally, the entry may be multiline. Prompt before
	        overwriting existing password unless forced.
	    $PROGRAM edit pass-name
	        Insert a new password or edit an existing password using ${EDITOR:-vi}.
	    $PROGRAM generate [--no-symbols,-n] [--clip,-c] [--in-place,-i | --force,-f] pass-name [pass-length]
	        Generate a new password of pass-length (or $GENERATED_LENGTH if unspecified) with optionally no symbols.
	        Optionally put it on the clipboard and clear board after $CLIP_TIME seconds.
	        Prompt before overwriting existing password unless forced.
	        Optionally replace only the first line of an existing file with a new password.
	    $PROGRAM rm [--recursive,-r] [--force,-f] pass-name
	        Remove existing password or directory, optionally forcefully.
	    $PROGRAM mv [--force,-f] old-path new-path
	        Renames or moves old-path to new-path, optionally forcefully, selectively reencrypting.
	    $PROGRAM cp [--force,-f] old-path new-path
	        Copies old-path to new-path, optionally forcefully, selectively reencrypting.
	    $PROGRAM git git-command-args...
	        If the password store is a git repository, execute a git command
	        specified by git-command-args.
	    $PROGRAM help
	        Show this text.
	    $PROGRAM version
	        Show version information.

	More information may be found in the pass(1) man page.
	_EOF
}

cmd_init() {
	local opts id_path=""
	opts="$($GETOPT -o p: -l path: -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-p|--path) id_path="$2"; shift 2 ;;
		--) shift; break ;;
	esac done

	[[ $err -ne 0 || $# -lt 1 ]] && die "Usage: $PROGRAM $COMMAND [--path=subfolder,-p subfolder] gpg-id..."
	[[ -n $id_path ]] && check_sneaky_paths "$id_path"
	[[ -n $id_path && ! -d $PREFIX/$id_path && -e $PREFIX/$id_path ]] && die "Error: $PREFIX/$id_path exists but is not a directory."

	local gpg_id="$PREFIX/$id_path/.gpg-id"
	set_git "$gpg_id"

	if [[ $# -eq 1 && -z $1 ]]; then
		[[ ! -f "$gpg_id" ]] && die "Error: $gpg_id does not exist and so cannot be removed."
		rm -v -f "$gpg_id" || exit 1
		if [[ -n $INNER_GIT_DIR ]]; then
			git -C "$INNER_GIT_DIR" rm -qr "$gpg_id"
			git_commit "Deinitialize ${gpg_id}${id_path:+ ($id_path)}."
		fi
		rmdir -p "${gpg_id%/*}" 2>/dev/null
	else
		mkdir -v -p "$PREFIX/$id_path"
		printf "%s\n" "$@" > "$gpg_id"
		local id_print="$(printf "%s, " "$@")"
		echo "Password store initialized for ${id_print%, }${id_path:+ ($id_path)}"
		git_add_file "$gpg_id" "Set GPG id to ${id_print%, }${id_path:+ ($id_path)}."
	fi

	git_add_file "$PREFIX/$id_path" "Reencrypt password store using new GPG id ${id_print%, }${id_path:+ ($id_path)}."
}





cmd_init() {
    [[ $# -ne 1 ]] && die "Usage: $PROGRAM init <gpg-id>"
    local new_key="$1"
    local gpg_id_file="$PREFIX/.gpg-id"

    # Guard: Don't accidentally overwrite an existing setup if you want to be safe
    if [[ -f "$gpg_id_file" ]]; then
        die "Error: Password store already initialized. Manually edit .gpg-id to change keys."
    fi

    mkdir -p "$PREFIX"
    echo "$new_key" > "$gpg_id_file"
    
    set_git
    if [[ -n $INNER_GIT_DIR ]]; then
        git -C "$INNER_GIT_DIR" add "$gpg_id_file"
        git_commit "Initialize password store with GPG ID $new_key"
    fi
    
    echo "Password store initialized for $new_key"
}




cmd_show() {
	local opts selected_line clip=0 
	opts="$($GETOPT -o c:: -l clip:: -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-c|--clip) clip=1; selected_line="${2:-1}"; shift 2 ;;
		--) shift; break ;;
	esac done

	[[ $err -ne 0 ]] && die "Usage: $PROGRAM $COMMAND [--clip[=line-number],-c[line-number]] [pass-name]"

	local pass
	local path="$1"
	local passfile="$PREFIX/$path.gpg"
	check_sneaky_paths "$path"
	if [[ -f $passfile ]]; then
		if [[ $clip -eq 0 ]]; then
		    pass="$($GPG -d "${GPG_OPTS[@]}" "$passfile" | $BASE64)" || exit $?
		    echo "$pass" | $BASE64 -d
		else
		    [[ $selected_line =~ ^[0-9]+$ ]] || die "Clip location '$selected_line' is not a number."
		    pass="$($GPG -d "${GPG_OPTS[@]}" "$passfile" | tail -n +${selected_line} | head -n 1)" || exit $?
		    [[ -n $pass ]] || die "There is no password at line ${selected_line}."
		    clip "$pass" "$path"
		fi
	elif [[ -d $PREFIX/$path ]]; then
		if [[ -z $path ]]; then
			echo "Password Store"
		else
			echo "${path%\/}"
		fi
		tree -N -C -l --noreport "$PREFIX/$path" 3>&- | tail -n +2 | sed -E 's/\.gpg(\x1B\[[0-9]+m)?( ->|$)/\1\2/g' # remove .gpg at end of line, but keep colors
	elif [[ -z $path ]]; then
		die "Error: password store is empty. Try \"pass init\"."
	else
		die "Error: $path is not in the password store."
	fi
}


cmd_show_aliases() {
    local map_file="$PREFIX/$MAP_NAME.gpg"
    if [[ -f "$map_file" ]]; then
        echo "Password Store (Mapped Aliases):"
        # Decrypt the map, extract just the alias (the part before the colon)
        $GPG "${GPG_OPTS[@]}" -d "$map_file" 2>/dev/null | cut -d':' -f1 | sort | sed 's/^/├── /'
    else
        echo "Password Store (No map found):"
        # Fallback to just listing the .gpg files if no map exists
        find "$PREFIX" -maxdepth 1 -name "*.gpg" -not -name "$MAP_NAME.gpg" | sed "s|^$PREFIX/||; s|\.gpg$||"
    fi
}






get_filename_from_alias() {
    local alias="$1"
    local map_file="$PREFIX/$MAP_NAME.gpg"
    [[ -f "$map_file" ]] || return 1
    
    # Decrypt map, find line starting with alias, extract the part after the colon
    $GPG -d "${GPG_OPTS[@]}" "$map_file" 2>/dev/null | grep "^${alias}:" | cut -d':' -f2
}






cmd_show() {
	local opts clip=0
	# Removed q:: and c:: (optional line numbers), now it's just a simple toggle
	opts="$($GETOPT -o c -l clip -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-c|--clip) clip=1; shift ;;
		--) shift; break ;;
	esac done

	[[ $err -ne 0 ]] && die "Usage: $PROGRAM $COMMAND [--clip,-c] [pass-name]"

	local path="$1"
	
	# If no alias is provided, list the mapped aliases
	if [[ -z "$path" ]]; then
		cmd_show_aliases # Calls the ls function we drafted earlier
		return 0
	fi

	check_sneaky_paths "$path"

	# Translate the human-readable alias to the obfuscated filename
	local filename=$(get_filename_from_alias "$path")
	
	[[ -z "$filename" ]] && die "Error: $path is not in the password store."

	local passfile="$PREFIX/$filename.gpg"

	if [[ -f "$passfile" ]]; then
		if [[ $clip -eq 0 ]]; then
			# Output the entire decrypted file directly to the terminal
			$GPG -d "${GPG_OPTS[@]}" "$passfile" || exit $?
		else
			# Extract only the first line for the clipboard
			local pass
			pass="$($GPG -d "${GPG_OPTS[@]}" "$passfile" | head -n 1)" || exit $?
			[[ -n "$pass" ]] || die "There is no password to put on the clipboard."
			clip "$pass" "$path"
		fi
	else
		# Failsafe in case the map has an entry but the file was manually deleted
		die "Error: $path mapped to $filename.gpg, but the file is missing."
	fi
}






cmd_find() {
	[[ $# -eq 0 ]] && die "Usage: $PROGRAM $COMMAND pass-names..."
	IFS="," eval 'echo "Search Terms: $*"'
	local terms="*$(printf '%s*|*' "$@")"
	tree -N -C -l --noreport -P "${terms%|*}" --prune --matchdirs --ignore-case "$PREFIX" 3>&- | tail -n +2 | sed -E 's/\.gpg(\x1B\[[0-9]+m)?( ->|$)/\1\2/g'
}




cmd_find() {
	[[ $# -eq 0 ]] && die "Usage: $PROGRAM find pass-names..."
	
	local map_file="$PREFIX/$MAP_NAME.gpg"
	[[ ! -f "$map_file" ]] && die "Error: Password store map is empty or missing."

	# Print the search terms nicely, like the original
	IFS="," eval 'echo "Search Terms: $*"'

	# Build a regex pattern from the arguments (e.g., "term1|term2|term3")
	local IFS="|"
	local pattern="$*"

	echo "Matching Aliases:"
	# Decrypt the map, search case-insensitively for the terms, grab just the alias, and format it
	$GPG -d "${GPG_OPTS[@]}" "$map_file" 2>/dev/null | grep -iE "$pattern" | cut -d':' -f1 | sort | sed 's/^/├── /'
}






cmd_insert() {
	local opts multiline=0 noecho=1 force=0
	opts="$($GETOPT -o mef -l multiline,echo,force -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-m|--multiline) multiline=1; shift ;;
		-e|--echo) noecho=0; shift ;;
		-f|--force) force=1; shift ;;
		--) shift; break ;;
	esac done

	[[ $err -ne 0 || ( $multiline -eq 1 && $noecho -eq 0 ) || $# -ne 1 ]] && die "Usage: $PROGRAM $COMMAND [--echo,-e | --multiline,-m] [--force,-f] pass-name"
	local path="${1%/}"
	local passfile="$PREFIX/$path.gpg"
	check_sneaky_paths "$path"
	set_git "$passfile"

	[[ $force -eq 0 && -e $passfile ]] && yesno "An entry already exists for $path. Overwrite it?"

	mkdir -p -v "$PREFIX/$(dirname -- "$path")"

	if [[ $multiline -eq 1 ]]; then
		echo "Enter contents of $path and press Ctrl+D when finished:"
		echo
		$GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" "${GPG_OPTS[@]}" || die "Password encryption aborted."
	elif [[ $noecho -eq 1 ]]; then
		local password password_again
		while true; do
			read -r -p "Enter password for $path: " -s password || exit 1
			echo
			read -r -p "Retype password for $path: " -s password_again || exit 1
			echo
			if [[ $password == "$password_again" ]]; then
				echo "$password" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" "${GPG_OPTS[@]}" || die "Password encryption aborted."
				break
			else
				die "Error: the entered passwords do not match."
			fi
		done
	else
		local password
		read -r -p "Enter password for $path: " -e password
		echo "$password" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" "${GPG_OPTS[@]}" || die "Password encryption aborted."
	fi
	git_add_file "$passfile" "Add given password for $path to store."
}



cmd_insert() {
	[[ $# -ne 1 ]] && die "Usage: $PROGRAM insert pass-name"

	local path="$1"
	check_sneaky_paths "$path"

	# 1. Map Lookup
	local filename
	filename=$(get_filename_from_alias "$path")
	local is_new=0

	if [[ -n "$filename" ]]; then
		echo -e "\e[93mWARNING: An entry already exists for '$path'.\e[0m"
		echo "Proceeding will overwrite the existing password. Press Ctrl+C to abort."
		echo
	else
		filename=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 12)
		is_new=1
	fi

	local passfile="$PREFIX/$filename.gpg"

	# 2. Strict Double-Prompt
	local password password_again
	while true; do
		read -r -p "Enter password for $path: " -s password || exit 1
		echo
		read -r -p "Retype password for $path: " -s password_again || exit 1
		echo
		if [[ "$password" == "$password_again" ]]; then
			# Encrypt directly
			echo "$password" | $GPG -e -r "$GPG_RECIPIENT" -o "$passfile" "${GPG_OPTS[@]}" || die "Password encryption aborted."
			break
		else
			echo "Error: the entered passwords do not match."
		fi
	done

	git_add_file "$passfile" "Add password for $path to store."

	# 3. Update Map (Only if new)
	if [[ $is_new -eq 1 ]]; then
		local map_file="$PREFIX/$MAP_NAME.gpg"
		local map_content=""
		[[ -f "$map_file" ]] && map_content=$($GPG -d "${GPG_OPTS[@]}" "$map_file" 2>/dev/null)
		
		# Append and re-encrypt
		echo -e "${map_content}\n${path}:${filename}" | sed '/^$/d' | $GPG -e -r "$GPG_RECIPIENT" -o "$map_file" "${GPG_OPTS[@]}"
		git_add_file "$map_file" "Update map with alias $path."
	fi
}




cmd_insert() {
	local opts generate=0 clip=0 length="${GENERATED_LENGTH:-24}"
	opts="$($GETOPT -o gc -l generate,clip -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-g|--generate) generate=1; shift ;;
		-c|--clip) clip=1; shift ;;
		--) shift; break ;;
	esac done

	# Accepts an optional length argument if generating
	[[ $err -ne 0 || $# -lt 1 || $# -gt 2 ]] && die "Usage: $PROGRAM insert [-g] [-c] pass-name [length]"

	local path="$1"
	[[ -n "$2" ]] && length="$2"
	check_sneaky_paths "$path"

	[[ $length =~ ^[0-9]+$ && $length -gt 0 ]] || die "Error: pass-length \"$length\" must be a valid number."

	# 1. Map Lookup
	local filename
	filename=$(get_filename_from_alias "$path")
	local is_new=0

	if [[ -n "$filename" ]]; then
		echo -e "\e[93mWARNING: An entry already exists for '$path'.\e[0m"
		if [[ $generate -eq 1 ]]; then
			# Pause for the user if we are about to auto-generate over an existing file
			read -r -p "Press Enter to generate and OVERWRITE, or Ctrl+C to abort..."
		else
			echo "Proceeding will overwrite the existing password. Press Ctrl+C to abort."
			echo
		fi
	else
		filename=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 12)
		is_new=1
	fi

	local passfile="$PREFIX/$filename.gpg"
	local password password_again

	# 2. Acquire Password (Generate vs Prompt)
	if [[ $generate -eq 1 ]]; then
		# Assuming $CHARACTER_SET is defined at the top of your script like the original
		read -r -n $length password < <(LC_ALL=C tr -dc "${CHARACTER_SET:-a-zA-Z0-9!@#$%^&*()_+{}|:<>?=}" < /dev/urandom)
		[[ ${#password} -eq $length ]] || die "Could not generate password."
		
		if [[ $clip -eq 1 ]]; then
			clip "$password" "$path"
		else
			printf "\e[1mThe generated password for \e[4m%s\e[24m is:\e[0m\n\e[1m\e[93m%s\e[0m\n" "$path" "$password"
		fi
	else
		while true; do
			read -r -p "Enter password for $path: " -s password || exit 1
			echo
			read -r -p "Retype password for $path: " -s password_again || exit 1
			echo
			if [[ "$password" == "$password_again" ]]; then
				break
			else
				echo "Error: the entered passwords do not match."
			fi
		done
	fi

	# 3. Encrypt and Save
	echo "$password" | $GPG -e -r "$GPG_RECIPIENT" -o "$passfile" "${GPG_OPTS[@]}" || die "Password encryption aborted."
	git_add_file "$passfile" "Add/Update password for $path."

	# 4. Update Map (Only if new)
	if [[ $is_new -eq 1 ]]; then
		local map_file="$PREFIX/$MAP_NAME.gpg"
		local map_content=""
		[[ -f "$map_file" ]] && map_content=$($GPG -d "${GPG_OPTS[@]}" "$map_file" 2>/dev/null)
		
		echo -e "${map_content}\n${path}:${filename}" | sed '/^$/d' | $GPG -e -r "$GPG_RECIPIENT" -o "$map_file" "${GPG_OPTS[@]}"
		git_add_file "$map_file" "Update map with alias $path."
	fi
}







cmd_edit() {
	[[ $# -ne 1 ]] && die "Usage: $PROGRAM $COMMAND pass-name"

	local path="${1%/}"
	check_sneaky_paths "$path"
	mkdir -p -v "$PREFIX/$(dirname -- "$path")"
	local passfile="$PREFIX/$path.gpg"
	set_git "$passfile"

	tmpdir #Defines $SECURE_TMPDIR
	local tmp_file="$(mktemp -u "$SECURE_TMPDIR/XXXXXX")-${path//\//-}.txt"

	local action="Add"
	if [[ -f $passfile ]]; then
		$GPG -d -o "$tmp_file" "${GPG_OPTS[@]}" "$passfile" || exit 1
		action="Edit"
	fi
	${EDITOR:-vi} "$tmp_file"
	[[ -f $tmp_file ]] || die "New password not saved."
	$GPG -d -o - "${GPG_OPTS[@]}" "$passfile" 2>/dev/null | diff - "$tmp_file" &>/dev/null && die "Password unchanged."
	while ! $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$passfile" "${GPG_OPTS[@]}" "$tmp_file"; do
		yesno "GPG encryption failed. Would you like to try again?"
	done
	git_add_file "$passfile" "$action password for $path using ${EDITOR:-vi}."
}





cmd_edit() {
	[[ $# -ne 1 ]] && die "Usage: $PROGRAM edit pass-name"

	local path="$1"
	check_sneaky_paths "$path"

	# 1. Map Lookup
	local filename=$(get_filename_from_alias "$path")
	[[ -z "$filename" ]] && die "Error: $path is not in the password store."

	local passfile="$PREFIX/$filename.gpg"
	[[ -f "$passfile" ]] || die "Error: $path mapped to $filename.gpg, but file is missing."

	# 2. Secure Temporary Storage
	# This uses the tmpdir() helper we kept earlier to create a folder in RAM
	tmpdir 
	local tmp_file="$SECURE_TMPDIR/${path//\//-}" # Sanitize alias for filename

	# 3. Decrypt to RAM, Edit, then Re-encrypt
	# We use the flat $GPG_RECIPIENT variable here
	$GPG -d -o "$tmp_file" "${GPG_OPTS[@]}" "$passfile" || exit 1
	
	# Open in your preferred editor (defaults to vi if $EDITOR isn't set)
	${EDITOR:-vi} "$tmp_file"
	
	# Check if the file was actually changed/saved
	[[ -f "$tmp_file" ]] || die "Error: Temporary file disappeared."
	
	$GPG -e -r "$GPG_RECIPIENT" -o "$passfile" "${GPG_OPTS[@]}" "$tmp_file" || die "Password encryption failed."
	
	# 4. Version Control
	git_add_file "$passfile" "Edit password for $path using ${EDITOR:-vi}."
}







cmd_delete() {
	local opts recursive="" force=0
	opts="$($GETOPT -o rf -l recursive,force -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-r|--recursive) recursive="-r"; shift ;;
		-f|--force) force=1; shift ;;
		--) shift; break ;;
	esac done
	[[ $# -ne 1 ]] && die "Usage: $PROGRAM $COMMAND [--recursive,-r] [--force,-f] pass-name"
	local path="$1"
	check_sneaky_paths "$path"

	local passdir="$PREFIX/${path%/}"
	local passfile="$PREFIX/$path.gpg"
	[[ -f $passfile && -d $passdir && $path == */ || ! -f $passfile ]] && passfile="${passdir%/}/"
	[[ -e $passfile ]] || die "Error: $path is not in the password store."
	set_git "$passfile"

	[[ $force -eq 1 ]] || yesno "Are you sure you would like to delete $path?"

	rm $recursive -f -v "$passfile"
	set_git "$passfile"
	if [[ -n $INNER_GIT_DIR && ! -e $passfile ]]; then
		git -C "$INNER_GIT_DIR" rm -qr "$passfile"
		set_git "$passfile"
		git_commit "Remove $path from store."
	fi
	rmdir -p "${passfile%/*}" 2>/dev/null
}




cmd_delete() {
	[[ $# -ne 1 ]] && die "Usage: $PROGRAM delete pass-name"

	local path="$1"
	check_sneaky_paths "$path"

	# 1. Map Lookup: Identify the ghost file
	local filename=$(get_filename_from_alias "$path")
	[[ -z "$filename" ]] && die "Error: $path is not in the password store."

	local passfile="$PREFIX/$filename.gpg"
	[[ -f "$passfile" ]] || die "Error: $path mapped to $filename.gpg, but the file is missing."

	# 2. Confirmation (The Arch Way)
	# No -f flag. If they don't want to delete, they Ctrl+C.
	echo -e "\e[91mDANGER: You are about to permanently delete '$path'.\e[0m"
	read -r -p "Press Enter to confirm, or Ctrl+C to abort..."

	# 3. Physical Removal
	# We use shred if available, otherwise rm -f
	if command -v shred &>/dev/null; then
		shred -u "$passfile"
	else
		rm -f "$passfile"
	fi

	# 4. Scrub the Map
	local map_file="$PREFIX/$MAP_NAME.gpg"
	if [[ -f "$map_file" ]]; then
		local map_content
		# Decrypt, filter out the line starting with our alias, and re-encrypt
		map_content=$($GPG -d "${GPG_OPTS[@]}" "$map_file" 2>/dev/null | grep -v "^${path}:")
		echo "$map_content" | sed '/^$/d' | $GPG -e -r "$GPG_RECIPIENT" -o "$map_file" "${GPG_OPTS[@]}"
	fi

	# 5. Git Integration
	if [[ -n $INNER_GIT_DIR ]]; then
		git -C "$INNER_GIT_DIR" rm -q "$passfile" 2>/dev/null
		git -C "$INNER_GIT_DIR" add "$map_file"
		git_commit "Remove $path and update map."
	fi

	echo "Removed '$path' from the password store."
}





cmd_git() {
	set_git "$PREFIX/"
	if [[ $1 == "init" ]]; then
		INNER_GIT_DIR="$PREFIX"
		git -C "$INNER_GIT_DIR" "$@" || exit 1
		git_add_file "$PREFIX" "Add current contents of password store."

		echo '*.gpg diff=gpg' > "$PREFIX/.gitattributes"
		git_add_file .gitattributes "Configure git repository for gpg file diff."
		git -C "$INNER_GIT_DIR" config --local diff.gpg.binary true
		git -C "$INNER_GIT_DIR" config --local diff.gpg.textconv "$GPG -d ${GPG_OPTS[*]}"
	elif [[ -n $INNER_GIT_DIR ]]; then
		tmpdir nowarn #Defines $SECURE_TMPDIR. We don't warn, because at most, this only copies encrypted files.
		export TMPDIR="$SECURE_TMPDIR"
		git -C "$INNER_GIT_DIR" "$@"
	else
		die "Error: the password store is not a git repository. Try \"$PROGRAM git init\"."
	fi
}






cmd_git() {
	set_git "$PREFIX/"
	if [[ $1 == "init" ]]; then
		INNER_GIT_DIR="$PREFIX"
		git -C "$INNER_GIT_DIR" "$@" || exit 1
		
		# Attributes for transparent GPG diffing
		echo '*.gpg diff=gpg' > "$PREFIX/.gitattributes"
		git -C "$INNER_GIT_DIR" add ".gitattributes"
		git_commit "Configure git repository for gpg file diff."
		
		# Configure the diff engine to use your GPG settings
		git -C "$INNER_GIT_DIR" config --local diff.gpg.binary true
		git -C "$INNER_GIT_DIR" config --local diff.gpg.textconv "$GPG -d ${GPG_OPTS[*]}"
	elif [[ -n "$INNER_GIT_DIR" ]]; then
		# Secure temp dir for git operations (like merges/diffs)
		tmpdir nowarn 
		export TMPDIR="$SECURE_TMPDIR"
		git -C "$INNER_GIT_DIR" "$@"
	else
		die "Error: the password store is not a git repository. Try \"$PROGRAM git init\"."
	fi
}







#
# END subcommand functions
#

PROGRAM="${0##*/}"
COMMAND="${1:-show}"

case "$1" in
	init) shift;			cmd_init "$@" ;;
	help|--help) shift;		cmd_usage "$@" ;;
	version|--version) shift;	cmd_version "$@" ;;
	show|ls|list) shift;		cmd_show "$@" ;;
	find|search) shift;		cmd_find "$@" ;;
	grep) shift;			cmd_grep "$@" ;;
	insert|add) shift;		cmd_insert "$@" ;;
	edit) shift;			cmd_edit "$@" ;;
	generate) shift;		cmd_generate "$@" ;;
	delete|rm|remove) shift;	cmd_delete "$@" ;;
	git) shift;			cmd_git "$@" ;;
	*)				cmd_show "$@" ;;
esac
exit 0
