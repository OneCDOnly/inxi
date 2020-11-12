#!/usr/bin/env bash
############################################################################
# inxi.sh - (C)opyright 2020 OneCD [one.cd.only@gmail.com]
#
# This script is part of the 'inxi' package
#
# For more info: []
#
# Available in the Qnapclub Store: []
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

TARGETBIN_PATHFILE=/usr/bin/inxi

case "$1" in
    start)
        if ! command -v perl; then
            echo "'inxi' requires a Perl interpreter to be installed."
            exit 1
        fi
        [[ ! -e $TARGETBIN_PATHFILE ]] && ln -s $(/sbin/getcfg inxi Install_Path -f /etc/config/qpkg.conf)/inxi.pl "$TARGETBIN_PATHFILE"
        ;;
    stop)
        [[ -L $TARGETBIN_PATHFILE ]] && rm -f "$TARGETBIN_PATHFILE"
        ;;
    restart)
        $0 stop
        $0 start
        ;;
    *)
        echo "run init as: $0 {start|stop|restart}"
        echo "to see everything: inxi -Fxxxm"
        ;;
esac

exit 0
