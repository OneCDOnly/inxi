#!/usr/bin/env bash
####################################################################################
# inxi.sh
#   Copyright 2020-2025 OneCD
#
# Contact:
#	one.cd.only@gmail.com
#
# Description:
#   This script is part of the 'inxi' package
#
# Application source:
#   https://codeberg.org/smxi/inxi
#
# QPKG source:
#   https://github.com/OneCDOnly/inxi
#
# Available via the sherpa package manager:
#	https://git.io/sherpa
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see http://www.gnu.org/licenses/
############################################################################

set -o nounset -o pipefail
shopt -s extglob
[[ -L /dev/fd ]] || ln -fns /proc/self/fd /dev/fd		# KLUDGE: `/dev/fd` isn't always created by QTS.
readonly r_user_args_raw=$*

Init()
    {

    readonly r_qpkg_name=inxi

    # KLUDGE: mark QPKG installation as complete.

    /sbin/setcfg $r_qpkg_name Status complete -f /etc/config/qpkg.conf

    # KLUDGE: 'clean' the QTS 4.5.1+ App Center notifier status.

    [[ -e /sbin/qpkg_cli ]] && /sbin/qpkg_cli --clean $r_qpkg_name &> /dev/null

    local -r r_qpkg_path=$(/sbin/getcfg $r_qpkg_name Install_Path -f /etc/config/qpkg.conf)
        readonly r_launcher_pathfile=$r_qpkg_path/inxi.pl
    readonly r_qpkg_version=$(/sbin/getcfg $r_qpkg_name Version -f /etc/config/qpkg.conf)
    readonly r_service_action_pathfile=/var/log/$r_qpkg_name.action
	readonly r_service_result_pathfile=/var/log/$r_qpkg_name.result
    readonly r_userlink_pathfile=/usr/bin/inxi

    }

StartQPKG()
    {

	if IsNotQPKGEnabled; then
		echo -e "This QPKG is disabled. Please enable it first with:\n\tqpkg_service enable $r_qpkg_name"
		return 1
	else
        if [[ ! -L $r_userlink_pathfile && -e $r_launcher_pathfile ]]; then
            ln -s "$r_launcher_pathfile" "$r_userlink_pathfile"

            if [[ -L $r_userlink_pathfile ]]; then
                echo "symlink created: $r_userlink_pathfile"
            else
                LogWrite 'error: unable to create symlink to the launcher' 2
                echo "error: unable to create symlink to 'inxi' launcher!"
                return 1
            fi
        else
            echo "symlink exists: $r_userlink_pathfile"
        fi
	fi

    return 0

    }

StopQPKG()
    {

    if [[ -L $r_userlink_pathfile ]]; then
        rm -f "$r_userlink_pathfile"
        echo "symlink removed: $r_userlink_pathfile"

        if [[ -L $r_userlink_pathfile ]]; then
            LogWrite 'error: unable to remove symlink to the launcher' 2
            echo "error: unable to remove symlink to 'inxi' launcher!"
            return 1
        fi
    fi

    return 0

    }

StatusQPKG()
    {

    if [[ -L $r_userlink_pathfile ]]; then
        echo active
        exit 0
    else
        echo inactive
        exit 1
    fi

    }

ShowTitle()
    {

    echo "$(ShowAsTitleName) $(ShowAsVersion)"

    }

ShowAsTitleName()
	{

	TextBrightWhite $r_qpkg_name

	}

ShowAsVersion()
	{

	printf '%s' "v$r_qpkg_version"

	}

ShowAsUsage()
    {

    echo -e "\nThis service-script manages the symlink to the 'inxi' launcher."
    echo -e "\nUsage: $0 {start|stop|restart|status}"
    echo -e "\nTo see a basic 'inxi' run: inxi"
    echo -e "\nTo see more of what 'inxi' can do: inxi -Ffxxxm"

	}

LogWrite()
    {

	# Inputs: (local)
    #   $1 = message to write into NAS system log
    #   $2 = event type:
    #       0 = Information
    #       1 = Warning
    #       2 = Error

    /sbin/log_tool --append "[$r_qpkg_name] ${1:-}" --type "${2:-}"

    }

SetServiceAction()
	{

	service_action=${1:-none}
	CommitServiceAction
	SetServiceResultAsInProgress

	}

SetServiceResultAsOK()
	{

	service_result=ok
	CommitServiceResult

	}

SetServiceResultAsFailed()
	{

	service_result=failed
	CommitServiceResult

	}

SetServiceResultAsInProgress()
	{

	# Selected action is in-progress and hasn't generated a result yet.

	service_result=in-progress
	CommitServiceResult

	}

CommitServiceAction()
	{

    echo "$service_action" > "$r_service_action_pathfile"

	}

CommitServiceResult()
	{

    echo "$service_result" > "$r_service_result_pathfile"

	}

TextBrightWhite()
	{

	[[ -n ${1:-} ]] || return

    printf '\033[1;97m%s\033[0m' "${1:-}"

	}

IsQPKGEnabled()
	{

	# Inputs: (local)
	#   $1 = (optional) package name to check. If unspecified, default is $r_qpkg_name

	# Outputs: (local)
	#   $? = 0 : true
	#   $? = 1 : false

	[[ $(Lowercase "$(/sbin/getcfg ${1:-$r_qpkg_name} Enable -d false -f /etc/config/qpkg.conf)") = true ]]

	}

IsNotQPKGEnabled()
	{

	# Inputs: (local)
	#   $1 = (optional) package name to check. If unspecified, default is $r_qpkg_name

	# Outputs: (local)
	#   $? = 0 : true
	#   $? = 1 : false

	! IsQPKGEnabled "${1:-$r_qpkg_name}"

	}

Lowercase()
	{

	/bin/tr 'A-Z' 'a-z' <<< "${1:-}"

	}

Init

user_arg=${r_user_args_raw%% *}		# Only process first argument.

case $user_arg in
    ?(--)restart)
        SetServiceAction restart

        if StopQPKG && StartQPKG; then
            SetServiceResultAsOK
        else
            SetServiceResultAsFailed
        fi
        ;;
    ?(--)start)
        SetServiceAction start

        if StartQPKG; then
            SetServiceResultAsOK
        else
            SetServiceResultAsFailed
        fi
        ;;
    ?(-)s|?(--)status)
        StatusQPKG
        ;;
    ?(--)stop)
        SetServiceAction stop

        if StopQPKG; then
            SetServiceResultAsOK
        else
            SetServiceResultAsFailed
        fi
        ;;
    *)
        ShowTitle
        ShowAsUsage
esac

exit 0
