#!/usr/bin/env bash
############################################################################
# inxi.sh - (C)opyright 2020-2022 OneCD [one.cd.only@gmail.com]
#
# This script is part of the 'inxi' package
#
# For more info: []
#
# QPKG source: [https://github.com/OneCDOnly/inxi]
# Project source: [https://github.com/smxi/inxi]
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
# this program. If not, see http://www.gnu.org/licenses/.
############################################################################

Init()
    {

    readonly QPKG_NAME=inxi
    readonly CONFIG_PATHFILE=/etc/config/qpkg.conf

    if [[ ! -e $CONFIG_PATHFILE ]]; then
        echo "file not found [$CONFIG_PATHFILE]"
        SetServiceOperationResultFailed
        exit 1
    fi

    local APP_CENTER_NOTIFIER=/sbin/qpkg_cli     # only needed for QTS 4.5.1-and-later
    readonly LAUNCHER_PATHFILE=$(/sbin/getcfg $QPKG_NAME Install_Path -f $CONFIG_PATHFILE)/inxi.pl
    readonly USERLINK_PATHFILE=/usr/bin/inxi
    readonly SERVICE_STATUS_PATHFILE=/var/run/$QPKG_NAME.last.operation

    /sbin/setcfg "$QPKG_NAME" Status complete -f "$CONFIG_PATHFILE"

    # KLUDGE: force-cancel QTS 4.5.1 App Center notifier status as it's often wrong. :(
    [[ -e $APP_CENTER_NOTIFIER ]] && $APP_CENTER_NOTIFIER -c "$QPKG_NAME" > /dev/null 2>&1

    }

SetServiceOperationResultOK()
    {

    SetServiceOperationResult ok

    }

SetServiceOperationResultFailed()
    {

    SetServiceOperationResult failed

    }

SetServiceOperationResult()
    {

    # $1 = result of operation to recorded

    [[ -n $1 && -n $SERVICE_STATUS_PATHFILE ]] && echo "$1" > "$SERVICE_STATUS_PATHFILE"

    }

Init

case "$1" in
    start)
        [[ ! -L $USERLINK_PATHFILE && -e $LAUNCHER_PATHFILE ]] && ln -s "$LAUNCHER_PATHFILE" "$USERLINK_PATHFILE"

        if [[ -L $USERLINK_PATHFILE ]]; then
            echo "symlink created: $USERLINK_PATHFILE"
        else
            echo "error: unable to create symlink to 'inxi' launcher!"
            SetServiceOperationResultFailed
            exit 1
        fi

        if ! command -v perl; then
            echo "Note: 'inxi' requires a Perl interpreter to be installed."
            /sbin/write_log "[inxi] requires a Perl interpreter to be installed" 1
            SetServiceOperationResultFailed
            exit 1
        fi

        SetServiceOperationResultOK
        ;;
    stop)
        if [[ -L $USERLINK_PATHFILE ]]; then
            rm -f "$USERLINK_PATHFILE"
            echo "symlink removed: $USERLINK_PATHFILE"
        fi

        SetServiceOperationResultOK
        ;;
    restart)
        $0 stop
        $0 start
        ;;
    *)
        echo "run service script as: $0 {start|stop|restart}"
        echo "to see everything: inxi -Ffxxxm"
esac

exit 0
