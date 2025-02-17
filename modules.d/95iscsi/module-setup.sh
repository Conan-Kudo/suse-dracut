#!/bin/bash

# called by dracut
check() {
    local _rootdev
    # If our prerequisites are not met, fail anyways.
    require_binaries hostname iscsi-iname iscsiadm iscsid || return 1

    # If hostonly was requested, fail the check if we are not actually
    # booting from root.

    is_iscsi() {
        local _dev=$1

        [[ -L "/sys/dev/block/$_dev" ]] || return
        cd "$(readlink -f "/sys/dev/block/$_dev")"
        until [[ -d sys || -d iscsi_session ]]; do
            cd ..
        done
        [[ -d iscsi_session ]]
    }

    [[ $hostonly ]] || [[ $mount_needs ]] && {
        pushd . >/dev/null
        for_each_host_dev_and_slaves is_iscsi || return 255
        popd >/dev/null
    }
    return 0
}

get_ibft_mod() {
    local ibft_mac=$1
    local iface_mac iface_mod
    # Return the iSCSI offload module for a given MAC address
    for iface_desc in $(iscsiadm -m iface | cut -f 2 -d ' '); do
        iface_mod=${iface_desc%%,*}
        iface_mac=${iface_desc#*,}
        iface_mac=${iface_mac%%,*}
        if [ "$ibft_mac" = "$iface_mac" ] ; then
            echo $iface_mod
            return 0
        fi
    done
}

install_ibft() {
    # When iBFT / iscsi_boot is detected:
    # - Use 'ip=ibft' to set up iBFT network interface
    #   Note: bnx2i is using a different MAC address of iSCSI offloading
    #         so the 'ip=ibft' parameter must not be set
    # - specify firmware booting cmdline parameter

    for d in /sys/firmware/* ; do
        if [ -d ${d}/ethernet0 ] ; then
            read ibft_mac < ${d}/ethernet0/mac
            ibft_mod=$(get_ibft_mod $ibft_mac)
        fi
        if [ -z "$ibft_mod" ] && [ -d ${d}/ethernet1 ] ; then
            read ibft_mac < ${d}/ethernet1/mac
            ibft_mod=$(get_ibft_mod $ibft_mac)
        fi
        if [ -d ${d}/initiator ] ; then
            if [ ${d##*/} = "ibft" ] && [ "$ibft_mod" != "bnx2i" ] ; then
                echo -n "rd.iscsi.ibft=1 "
            fi
            echo -n "rd.iscsi.firmware=1"
        fi
    done
}

install_iscsiroot() {
    local devpath=$1
    local scsi_path iscsi_lun session c d conn host flash
    local iscsi_session iscsi_address iscsi_port iscsi_targetname iscsi_tpgt

    scsi_path=${devpath%%/block*}
    [ "$scsi_path" = "$devpath" ] && return 1
    iscsi_lun=${scsi_path##*:}
    [ "$iscsi_lun" = "$scsi_path" ] && return 1
    session=${devpath%%/target*}
    [ "$session" = "$devpath" ] && return 1
    iscsi_session=${session##*/}
    [ "$iscsi_session" = "$session" ] && return 1
    host=${session%%/session*}
    [ "$host" = "$session" ] && return 1
    iscsi_host=${host##*/}

    for flash in ${host}/flashnode_sess-* ; do
	is_boot="0"
	if [[ -d "$flash" ]]; then
	    if [[ -r "$flash/is_boot_target" ]]; then
		is_boot=$(cat $flash/is_boot_target)
	    fi
	fi
        if [[ "$is_boot" -eq 1 ]]; then
            # qla4xxx flashnode session; skip iBFT discovery
            iscsi_initiator=$(cat /sys/class/iscsi_host/${iscsi_host}/initiatorname)
            echo "rd.iscsi.initiator=${iscsi_initiator}"
            return;
        fi
    done

    for d in ${session}/* ; do
        case $d in
	    *connection*)
	        c=${d##*/}
	        conn=${d}/iscsi_connection/${c}
	        if [ -d ${conn} ] ; then
		    iscsi_address=$(cat ${conn}/persistent_address)
		    iscsi_port=$(cat ${conn}/persistent_port)
	        fi
	        ;;
	    *session)
	        if [ -d ${d}/${iscsi_session} ] ; then
                    iscsi_initiator=$(cat ${d}/${iscsi_session}/initiatorname)
		    iscsi_targetname=$(cat ${d}/${iscsi_session}/targetname)
	        fi
	        ;;
        esac
    done

    [ -z "$iscsi_address" ] && return
    local_address=$(ip -o route get to $iscsi_address | sed -n 's/.*src \([0-9a-f.:]*\).*/\1/p')
    ifname=$(ip -o route get to $iscsi_address | sed -n 's/.*dev \([^ ]*\).*/\1/p')

    #follow ifcfg settings for boot protocol
    bootproto=$(sed -n "/BOOTPROTO/s/BOOTPROTO='\([[:alpha:]]*6\?\)4\?'/\1/p" /etc/sysconfig/network/ifcfg-$ifname)
    if [ $bootproto ]; then
        printf 'ip=%s:%s ' ${ifname} ${bootproto}
    else
        printf 'ip=%s:static ' ${ifname}
    fi

    if [ -e /sys/class/net/$ifname/address ] ; then
        ifmac=$(cat /sys/class/net/$ifname/address)
        printf 'ifname=%s:%s ' ${ifname} ${ifmac}
    fi

    if [ -n "$iscsi_address" -a -n "$iscsi_targetname" ] ; then
        if [ -n "$iscsi_port" -a "$iscsi_port" -eq 3260 ] ; then
            iscsi_port=
        fi
        if [ -n "$iscsi_lun" -a "$iscsi_lun" -eq 0 ] ; then
            iscsi_lun=
        fi
        # In IPv6 case rd.iscsi.initatior= must pass address in [] brackets
        case "$iscsi_address" in
            *:*)
                iscsi_address="[$iscsi_address]"
                ;;
        esac
        # Must be two separate lines, so that "sort | uniq" commands later
        # can sort out rd.iscsi.initiator= duplicates
        echo "rd.iscsi.initiator=${iscsi_initiator}"
        echo "netroot=iscsi:${iscsi_address}::${iscsi_port}:${iscsi_lun}:${iscsi_targetname}"
        echo "rd.neednet=1"
    fi
    return 0
}


install_softiscsi() {
    [ -d /sys/firmware/ibft ] && return 0

    is_softiscsi() {
        local _dev=$1
        local iscsi_dev

        [[ -L "/sys/dev/block/$_dev" ]] || return
        iscsi_dev=$(cd -P /sys/dev/block/$_dev; echo $PWD)
        install_iscsiroot $iscsi_dev
    }

    for_each_host_dev_and_slaves_all is_softiscsi || return 255
    return 0
}

# called by dracut
depends() {
    echo network rootfs-block
}

# called by dracut
installkernel() {
    local _arch=$(uname -m)

    instmods bnx2i qla4xxx cxgb3i cxgb4i be2iscsi qedi
    hostonly="" instmods iscsi_tcp iscsi_ibft crc32c iscsi_boot_sysfs
    iscsi_module_filter() {
        local _funcs='iscsi_register_transport'
        # subfunctions inherit following FDs
        local _merge=8 _side2=9
        function bmf1() {
            local _f
            while read _f || [ -n "$_f" ]; do
                case "$_f" in
                    *.ko)    [[ $(<         "$_f" | tr -cd '[:print:]') =~ $_funcs ]] && echo "$_f" ;;
                    *.ko.gz) [[ $(gzip -dc <"$_f" | tr -cd '[:print:]') =~ $_funcs ]] && echo "$_f" ;;
                    *.ko.xz) [[ $(xz -dc   <"$_f" | tr -cd '[:print:]') =~ $_funcs ]] && echo "$_f" ;;
                esac
            done
            return 0
        }

        function rotor() {
            local _f1 _f2
            while read _f1 || [ -n "$_f1" ]; do
                echo "$_f1"
                if read _f2; then
                    echo "$_f2" 1>&${_side2}
                fi
            done | bmf1 1>&${_merge}
            return 0
        }
        # Use two parallel streams to filter alternating modules.
        set +x
        eval "( ( rotor ) ${_side2}>&1 | bmf1 ) ${_merge}>&1"
        [[ $debug ]] && set -x
        return 0
    }

    { find_kernel_modules_by_path drivers/scsi; if [ "$_arch" = "s390" -o "$_arch" = "s390x" ]; then find_kernel_modules_by_path drivers/s390/scsi; fi;} \
    | iscsi_module_filter  |  instmods
}

# called by dracut
cmdline() {
    local _iscsiconf=$(install_ibft)
    {
        if [ "$_iscsiconf" ] ; then
            echo ${_iscsiconf}
        else
            install_softiscsi
        fi
    } | sort | uniq
}

# called by dracut
install() {
    inst_multiple -o iscsiuio
    inst_libdir_file 'libgcc_s.so*'
    inst_multiple umount hostname iscsi-iname iscsiadm iscsid

    ln -sf $systemdsystemunitdir/iscsid.socket $systemdsystemunitdir/sockets.target.wants/iscsid.socket
    ln -sf $systemdsystemunitdir/iscsiuio.socket $systemdsystemunitdir/sockets.target.wants/iscsiuio.socket

    inst_multiple -o \
        $systemdsystemunitdir/iscsid.socket \
        $systemdsystemunitdir/iscsid.service \
        $systemdsystemunitdir/iscsiuio.service \
        $systemdsystemunitdir/iscsiuio.socket \
        $systemdsystemunitdir/sockets.target.wants/iscsid.socket \
        $systemdsystemunitdir/sockets.target.wants/iscsiuio.socket

    [[ -d /etc/iscsi ]] && inst_dir $(/usr/bin/find /etc/iscsi)

    # Detect iBFT and perform mandatory steps
    if [[ $hostonly_cmdline == "yes" ]] ; then
        local _iscsiconf=$(cmdline)
        [[ $_iscsiconf ]] && printf "%s\n" "$_iscsiconf" >> "${initdir}/etc/cmdline.d/95iscsi.conf"
    fi

    inst_hook cmdline 90 "$moddir/parse-iscsiroot.sh"
    inst_hook cleanup 90 "$moddir/cleanup-iscsi.sh"
    inst "$moddir/iscsiroot.sh" "/sbin/iscsiroot"
    if ! dracut_module_included "systemd"; then
        inst "$moddir/mount-lun.sh" "/bin/mount-lun.sh"
    else
        inst_multiple -o \
                      $systemdsystemunitdir/iscsi.service \
                      $systemdsystemunitdir/iscsid.service \
                      $systemdsystemunitdir/iscsid.socket \
                      $systemdsystemunitdir/iscsiuio.service \
                      $systemdsystemunitdir/iscsiuio.socket \
                      iscsiadm iscsid

        mkdir -p "${initdir}/$systemdsystemunitdir/sockets.target.wants"
        for i in \
                iscsiuio.socket \
            ; do
            ln_r "$systemdsystemunitdir/${i}" "$systemdsystemunitdir/sockets.target.wants/${i}"
        done

        mkdir -p "${initdir}/$systemdsystemunitdir/basic.target.wants"
        for i in \
                iscsid.service \
                iscsiuio.service \
            ; do
            ln_r "$systemdsystemunitdir/${i}" "$systemdsystemunitdir/basic.target.wants/${i}"
        done

        # Make sure iscsid is started after dracut-cmdline and ready for the initqueue
        mkdir -p "${initdir}/$systemdsystemunitdir/iscsid.service.d"
        (
            echo "[Unit]"
            echo "After=dracut-cmdline.service"
            echo "Before=dracut-initqueue.service"
        ) > "${initdir}/$systemdsystemunitdir/iscsid.service.d/dracut.conf"

        # The iscsi deamon does not need to wait for any storage inside initrd
        mkdir -p "${initdir}/$systemdsystemunitdir/iscsid.socket.d"
        (
            echo "[Unit]"
            echo "DefaultDependencies=no"
            echo "Conflicts=shutdown.target"
            echo "Before=shutdown.target sockets.target"
        ) > "${initdir}/$systemdsystemunitdir/iscsid.socket.d/dracut.conf"
        mkdir -p "${initdir}/$systemdsystemunitdir/iscsiuio.socket.d"
        (
            echo "[Unit]"
            echo "DefaultDependencies=no"
            echo "Conflicts=shutdown.target"
            echo "Before=shutdown.target sockets.target"
        ) > "${initdir}/$systemdsystemunitdir/iscsiuio.socket.d/dracut.conf"

    fi
    inst_dir /var/lib/iscsi
    dracut_need_initqueue
}
