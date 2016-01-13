#!/bin/bash

# This script is based on the isntall-mero-services-script from mero sources.

readonly BASENAME=$(basename $0)

# variables 
dry_run=false
link_files=false
action='install'

help()
{
    [[ $1 == stdout ]] && usage || usage >&2
    exit 1
}

usage()
{
	cat <<USAGE_END 
Install systemd sscripts for development or testing use.
Usage: $BASE_NAME [-h|--help] [-n|--dry-run] [-u|--uninstall]

	-n|--dry-run	Don't perform any action, just show what would be
			installed/uninstalled.

	-l|--link	Symlink files instread of copying them.

	-u|--uninstall	Remove files and directories witch were installed by this script

	-h|--help	Print this help.
USAGE_END
}

#
# Parse CLI options
#

parse_cli_options()
{
    # Note that we use `"$@"' to let each command-line parameter expand to a
    # separate word. The quotes around `$@' are essential!
    # We need TEMP as the `eval set --' would nuke the return value of getopt.
    TEMP=$( getopt -o hnlu --long help,dry-run,link,uninstall -n "$PROG_NAME" -- "$@" )

    [[ $? != 0 ]] && help

    # Note the quotes around `$TEMP': they are essential!
    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            -h|--help)          help stdout ;;
            -n|--dry-run)       dry_run=true; shift ;;
            -l|--link)          link_files=true; shift ;;
            -u|--uninstall)     action=uninstall; shift ;;
            --)                 shift; break ;;
            *)                  echo 'getopt: internal error...'; exit 1 ;;
        esac
    done
}

#
# Utility functions
#

die()
{
    echo "$@" >&2
    exit 1
}

run()
{
    local cmd="$*"

    $dry_run && echo $cmd
    $dry_run || $cmd
}


install_files()
{

    local cmd='cp -vf'
    $link_files && cmd='ln -sfv'

    dir='/usr/lib/systemd/system'
    if [[ -d $dir ]] ; then
        for file in 'systemd/halond.service' \
                    'systemd/halon-satellite.service' \
                    ;
        do
            run "$cmd $(pwd)/$file $dir"
        done
    fi

    dir='/etc/sysconfig'
    [[ ! -d $dir ]] && run "mkdir -vp $dir"
    for file in 'systemd/sysconfig/halond' \
                'systemd/sysconfig/halon-satellite' ;
    do
        run "$cmd $(pwd)/$file $dir"
    done
    run "echo LD_LIBRARY_PATH=/mero/mero/.libs >> $dir/halond"

    dir="/usr/local/bin"
    [[ ! -d $dir ]] && run "mkdir -vp $dir"
    file_list="mero-halon/.stack-work/dist/*/*/build/halond/halond
               mero-halon/.stack-work/dist/*/*/build/halonctl/halonctl
              "
    for file in $file_list
    do
    	[[ -s $file ]] && run "$cmd $(pwd)/$file $dir"
    done

    $dry_run || {
        [[ -x /sbin/initctl ]] && initctl reload-configuration
        [[ -x /usr/bin/systemctl ]] && systemctl daemon-reload
    }
}

uninstall_files()
{
    file_list='/etc/sysconfig/halond
               /etc/sysconfig/halond-satellite          
               '

    if [[ -d /usr/lib/systemd/system ]] ; then
        file_list+='/usr/lib/systemd/system/halond.service
                    /usr/lib/systemd/system/halon-satellite.service
                   '
    fi

    for file in $file_list
    do
        [[ -s $file ]] && run "rm -v $file"
    done

    $dry_run || {
        [[ -x /sbin/initctl ]] && initctl reload-configuration
        [[ -x /usr/bin/systemctl ]] && systemctl daemon-reload
    }
}

#
# Main
#

# exit immediately if one the commands exits with a non-zero status
set -e

parse_cli_options $@

if ! $dry_run && [[ $UID -ne 0 ]]; then
    die 'Error: Please, run this script with "root" privileges or use' \
        '-n|--dry-run option.'
fi

case $action in
    install)    install_files ;;
    uninstall)  uninstall_files ;;
    *)          die "Error: unknown action '$action'." ;;
esac

