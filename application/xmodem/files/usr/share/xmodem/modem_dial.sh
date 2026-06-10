#!/bin/sh
source /lib/functions.sh
#运行目录
MODEM_RUNDIR="/var/run/xmodem"
SCRIPT_DIR="/usr/share/xmodem"

modem_config=$1
mkdir -p "${MODEM_RUNDIR}/${modem_config}_dir"
log_file="${MODEM_RUNDIR}/${modem_config}_dir/dial_log"
debug_subject="modem_dial"
source "${SCRIPT_DIR}/generic.sh"
touch $log_file

exec_pre_dial()
{
    section=$1
    /usr/share/xmodem/modem_hook.sh $section pre_dial
}

get_led()
{
    config_foreach get_led_by_slot modem-slot
}

get_led_by_slot()
{
    local cfg="$1"
    config_get slot "$cfg" slot
    if [ "$modem_slot" = "$slot" ];then
        config_get sim_led "$cfg" sim_led
        config_get net_led "$cfg" net_led
    fi
}

get_slot_network_config()
{
    local cfg="$1"
    local slot
    config_get slot "$cfg" slot
    if [ "$modem_slot" = "$slot" ];then
        config_get ethernet_5g "$cfg" ethernet_5g
        config_get slot_bridge_port "$cfg" bridge_port
    fi
}

sanitize_bridge_id()
{
    local value="$1"
    value=$(printf '%s' "$value" | tr -c 'A-Za-z0-9_-' '_')
    value=$(printf '%s' "$value" | sed 's/^_\\+//; s/_\\+$//')
    echo "$value"
}

make_bridge_device_name()
{
    local source="$1"
    local sanitized

    sanitized=$(sanitize_bridge_id "$source")
    [ -z "$sanitized" ] && return 1
    printf 'b%s\n' "$sanitized" | cut -c1-15
}

get_bridge_device_section()
{
    local safe_cfg
    safe_cfg=$(sanitize_bridge_id "$modem_config")
    [ -z "$safe_cfg" ] && safe_cfg="modem"
    echo "xmodem_bridge_${safe_cfg}"
}

get_bridge_backup_section()
{
    local bridge_cfg="$1"
    local safe_cfg
    local safe_bridge

    safe_cfg=$(sanitize_bridge_id "$modem_config")
    safe_bridge=$(sanitize_bridge_id "$bridge_cfg")
    [ -z "$safe_cfg" ] && safe_cfg="modem"
    [ -z "$safe_bridge" ] && safe_bridge="bridge"
    echo "xmodem_bridge_backup_${safe_cfg}_${safe_bridge}"
}

bridge_name_conflict_cb()
{
    local cfg="$1"
    local name

    [ "$cfg" = "$bridge_name_allow_section" ] && return
    config_get name "$cfg" name
    [ "$name" = "$bridge_name_candidate" ] && bridge_name_conflict=1
}

bridge_name_in_use()
{
    local candidate="$1"
    local allow_section="$2"
    local current_name

    [ -z "$candidate" ] && return 0

    bridge_name_candidate="$candidate"
    bridge_name_allow_section="$allow_section"
    bridge_name_conflict=0
    config_load network
    config_foreach bridge_name_conflict_cb device
    current_name=$(uci -q get network.${allow_section}.name)
    if [ -d "/sys/class/net/$candidate" ] && [ "$current_name" != "$candidate" ]; then
        bridge_name_conflict=1
    fi
    [ "$bridge_name_conflict" = "1" ]
}

resolve_bridge_device_name()
{
    local bridge_section
    local preferred_name
    local fallback_name
    local current_name
    local seed
    local suffix

    bridge_section=$(get_bridge_device_section)
    current_name=$(uci -q get network.${bridge_section}.name)
    preferred_name=$(make_bridge_device_name "$alias")
    fallback_name=$(make_bridge_device_name "$modem_config")

    if [ -n "$preferred_name" ] && ! bridge_name_in_use "$preferred_name" "$bridge_section"; then
        echo "$preferred_name"
        return
    fi

    if [ -n "$fallback_name" ] && ! bridge_name_in_use "$fallback_name" "$bridge_section"; then
        echo "$fallback_name"
        return
    fi

    if [ -n "$current_name" ]; then
        echo "$current_name"
        return
    fi

    seed=$(sanitize_bridge_id "$modem_config")
    [ -z "$seed" ] && seed="modem"
    suffix=$(printf '%s' "$modem_config" | cksum | awk '{print $1}' | cut -c1-4)
    printf 'b%s%s\n' "$(printf '%s' "$seed" | cut -c1-10)" "$suffix" | cut -c1-15
}

collect_bridge_ports()
{
    local port="$1"

    [ -n "$bridge_ports" ] && bridge_ports="$bridge_ports $port" || bridge_ports="$port"
    [ "$port" = "$bridge_scan_target_port" ] && bridge_port_found=1
}

save_bridge_port_backup()
{
    local source_section="$1"
    local source_ports="$2"
    local backup_section

    backup_section=$(get_bridge_backup_section "$source_section")
    [ -n "$(uci -q get xmodem.${backup_section})" ] && return

    uci -q set xmodem.${backup_section}=bridge-port-backup
    uci -q set xmodem.${backup_section}.modem_config="${modem_config}"
    uci -q set xmodem.${backup_section}.device_section="${source_section}"
    uci -q set xmodem.${backup_section}.bridge_port="${bridge_port}"
    uci -q delete xmodem.${backup_section}.ports
    for port in $source_ports; do
        uci -q add_list xmodem.${backup_section}.ports="${port}"
    done
    bridge_xmodem_dirty=1
    m_debug "backup bridge device $source_section ports: $source_ports"
}

remove_bridge_port_from_device()
{
    local cfg="$1"
    local type

    [ "$cfg" = "$bridge_device_section" ] && return
    config_get type "$cfg" type
    [ "$type" = "bridge" ] || return

    bridge_ports=""
    bridge_port_found=0
    config_list_foreach "$cfg" ports collect_bridge_ports
    [ "$bridge_port_found" = "1" ] || return

    save_bridge_port_backup "$cfg" "$bridge_ports"
    uci -q delete network.${cfg}.ports
    for port in $bridge_ports; do
        [ "$port" = "$bridge_scan_target_port" ] && continue
        uci -q add_list network.${cfg}.ports="${port}"
    done
    bridge_network_dirty=1
    m_debug "remove bridge port $bridge_scan_target_port from bridge device $cfg"
}

ensure_bridge_device()
{
    local wwan_port="$1"
    local bridge_section
    local desired_ports
    local current_type
    local current_name
    local current_ports

    bridge_section=$(get_bridge_device_section)
    bridge_device_section="$bridge_section"
    bridge_device_name=$(resolve_bridge_device_name)
    current_type=$(uci -q get network.${bridge_section}.type)
    current_name=$(uci -q get network.${bridge_section}.name)
    current_ports=$(uci -q get network.${bridge_section}.ports)

    desired_ports="$bridge_port"
    [ -n "$wwan_port" ] && [ "$wwan_port" != "$bridge_port" ] && desired_ports="$desired_ports $wwan_port"

    if [ "$(uci -q get network.${bridge_section})" != "device" ] || [ "$current_type" != "bridge" ] || [ "$current_name" != "$bridge_device_name" ] || [ "$current_ports" != "$desired_ports" ]; then
        uci -q set network.${bridge_section}=device
        uci -q set network.${bridge_section}.name="${bridge_device_name}"
        uci -q set network.${bridge_section}.type='bridge'
        uci -q delete network.${bridge_section}.ports
        uci -q add_list network.${bridge_section}.ports="${bridge_port}"
        [ -n "$wwan_port" ] && [ "$wwan_port" != "$bridge_port" ] && uci -q add_list network.${bridge_section}.ports="${wwan_port}"
        bridge_network_dirty=1
        m_debug "set dedicated bridge ${bridge_device_name} ports: ${desired_ports}"
    fi
}

ensure_bridge_passthrough()
{
    local wwan_port="$1"

    bridge_device_name=""
    bridge_device_section=$(get_bridge_device_section)
    bridge_scan_target_port="$bridge_port"

    config_load network
    config_foreach remove_bridge_port_from_device device
    ensure_bridge_device "$wwan_port"
}

restore_bridge_backup_ports()
{
    local port="$1"

    [ -n "$port" ] && uci -q add_list network.${restore_bridge_section}.ports="${port}"
}

restore_bridge_port_backup()
{
    local cfg="$1"
    local bind_modem_config
    local source_section

    config_get bind_modem_config "$cfg" modem_config
    [ "$bind_modem_config" = "$modem_config" ] || return

    config_get source_section "$cfg" device_section
    if [ -n "$source_section" ] && [ -n "$(uci -q get network.${source_section})" ]; then
        uci -q delete network.${source_section}.ports
        restore_bridge_section="$source_section"
        config_list_foreach "$cfg" ports restore_bridge_backup_ports
        bridge_network_dirty=1
        m_debug "restore bridge device $source_section"
    fi

    uci -q delete xmodem.${cfg}
    bridge_xmodem_dirty=1
}

cleanup_bridge_passthrough()
{
    local bridge_section

    bridge_network_dirty=0
    bridge_xmodem_dirty=0

    config_load xmodem
    config_foreach restore_bridge_port_backup bridge-port-backup

    bridge_section=$(get_bridge_device_section)
    if [ -n "$(uci -q get network.${bridge_section})" ]; then
        uci -q delete network.${bridge_section}
        bridge_network_dirty=1
        m_debug "delete dedicated bridge section $bridge_section"
    fi
}

set_led()
{
    local type=$1
    local modem_config=$2
    local value=$3
    get_led "$modem_slot"
    case $type in
        sim)
            [ -z "$sim_led" ] && return
            echo $value > /sys/class/leds/$sim_led/brightness
            ;;
        net)
            [ -z "$net_led" ] && return
            cfg_name=$(echo $net_led |tr ":" "_") 
            uci batch << EOF
set system.n${cfg_name}=led
set system.n${cfg_name}.name=${modem_slot}_net_indicator
set system.n${cfg_name}.sysfs=${net_led}
set system.n${cfg_name}.trigger=netdev
set system.n${cfg_name}.dev=${value:-$modem_netcard}
set system.n${cfg_name}.mode="link tx rx"
commit system
EOF

            /etc/init.d/led restart
            ;;
    esac
}

unlock_sim()
{
    pin=$1
    sim_lock_file="/var/run/xmodem/${modem_config}_dir/pincode"
    lock ${sim_lock_file}.lock
    if [ -f $sim_lock_file ] && [ "$pin" = "$(cat $sim_lock_file)" ];then
        m_debug "pin code is already try"
    else
        
        res=$(at "$at_port" "AT+CPIN=\"$pin\"")
        case "$?" in
            0)
                m_debug "unlock sim card with pin code $pin success"
                ;;
            *)
                echo $pin > $sim_lock_file
                m_debug "info" "unlock sim card with pin code $pin failed,block try until nextboot"
                ;;
        esac
    fi
    lock -u ${sim_lock_file}.lock

}

get_platform_suggest_pdp_index()
{
    case $manufacturer in
    quectel)
        case $platform in
            lte)
                echo 3
                ;;
            *)
                echo 1
                ;;
        esac
    ;;
    fibocom)
        case $platform in
            mediatek)
                echo 3
                ;;
            intel)
                echo 0
                ;;
            *)
                echo 1
                ;;
        esac
    ;;
    *)
        echo 1
        ;;
    esac
}

update_config()
{
    config_load xmodem
    config_get state $modem_config state
    config_get enable_dial $modem_config enable_dial
    config_get modem_path $modem_config path
    config_get dial_tool $modem_config dial_tool
    config_get pdp_type $modem_config pdp_type
    config_get network_bridge $modem_config network_bridge
    config_get metric $modem_config metric
    config_get at_port $modem_config at_port
    config_get manufacturer $modem_config manufacturer
    config_get platform $modem_config platform
    config_get use_ubus $modem_config use_ubus
    config_get force_set_apn $modem_config force_set_apn
    config_get pdp_index $modem_config pdp_index
    [ -n "$pdp_index" ] && userset_pdp_index="1" || userset_pdp_index="0"
    config_get suggest_pdp_index $modem_config suggest_pdp_index
    [ -z "$suggest_pdp_index" ] && suggest_pdp_index=$(get_platform_suggest_pdp_index)
    [ -z "$pdp_index" ] && pdp_index=$suggest_pdp_index
    # L850/L860-GL (intel) NCM data is always on PDP context 0 (at_dial hard-codes
    # CGDATA M-RAW_IP,0); force it so check_ip/CGCONTRDP stay consistent even if a
    # user sets a different pdp_index in LuCI.
    [ "$platform" = "intel" ] && pdp_index=0
    config_get ra_master $modem_config ra_master
    config_get extend_prefix $modem_config extend_prefix
    config_get en_bridge $modem_config en_bridge
    config_get do_not_add_dns $modem_config do_not_add_dns
    config_get dns_list $modem_config dns_list
    config_get huawei_dial_mode $modem_config huawei_dial_mode
    config_get donot_nat $modem_config donot_nat 0
    config_get global_dial main enable_dial
    modem_slot=$(basename $modem_path)
    slot_bridge_port=""
    ethernet_5g=""
    bridge_port=""
    bridge_enabled=0
    # config_get ethernet_5g u$modem_config ethernet 转往口获取命令更新，待测试
    config_foreach get_slot_network_config modem-slot
    config_get alias $modem_config alias
    config_get device_bridge_port $modem_config bridge_port
    bridge_port="$slot_bridge_port"
    [ -n "$device_bridge_port" ] && bridge_port="$device_bridge_port"
    [ "$en_bridge" = "1" ] && [ -n "$bridge_port" ] && bridge_enabled=1
    driver=$(get_driver)
    update_sim_slot
    case $sim_slot in
        1)
        config_get apn $modem_config apn
        config_get username $modem_config username
        config_get password $modem_config password
        config_get auth $modem_config auth
        config_get pincode $modem_config pincode
        ;;
        2)
        config_get apn $modem_config apn2
        config_get username $modem_config username2
        config_get password $modem_config password2
        config_get auth $modem_config auth2
        config_get pincode $modem_config pincode2
        [ -z "$apn" ] && config_get apn $modem_config apn
        [ -z "$username" ] && config_get username $modem_config username
        [ -z "$password" ] && config_get password $modem_config password
        [ -z "$auth" ] && config_get auth $modem_config auth
        [ -z "$pin" ] && config_get pincode $modem_config pincode
        ;;
        *)
            config_get apn $modem_config apn
            config_get username $modem_config username
            config_get password $modem_config password
            config_get auth $modem_config auth
            config_get pincode $modem_config pincode
            ;;
    esac
    modem_net=$(find $modem_path -name net |tail -1)
    modem_netcard=$(ls $modem_net)
    interface_name=$modem_config
    [ -n "$alias" ] && interface_name=$alias
    interface6_name=${interface_name}v6
    if [ "$use_ubus" = "1" ]; then
        use_ubus_flag="-u"
    else
        use_ubus_flag=""
    fi
}

check_dial_prepare()
{
    cpin=$(at "$at_port" "AT+CPIN?")
    get_sim_status "$cpin"
    [ "$manufacturer" = "neoway" ] && {
        local res
        res=$(at $at_port 'AT+SIMCROSS=1,1;$MYCCID' | grep -q "ERROR")
        if [ $? -ne 0 ]; then
            sim_state_code="1"
        else
            sim_state_code="0"
        fi
    }
    case $sim_state_code in
        "0")
            m_debug "SIM not detected"
            ;;
        "1")
            m_debug "SIM ready"
            sim_fullfill=1
            ;;
        "2")
            m_debug "SIM PIN required"
            [ -n "$pincode" ] && unlock_sim $pincode
            ;;
        *)
            m_debug "info sim card state is $sim_state_code"
            ;;
    esac
    
    if [ "$sim_fullfill" = "1" ];then
        set_led "sim" $modem_config 255
    else
        set_led "sim" $modem_config 0
    fi
    if [ -n "$modem_netcard" ] && [ -d "/sys/class/net/$modem_netcard" ];then
        netdev_fullfill=1
    else
        netdev_fullfill=0
    fi

    if [ "$enable_dial" = "1" ] && [ "$sim_fullfill" = "1" ] && [ "$state" != "disabled" ] ;then
        config_fullfill=1
    fi
    if [ "$config_fullfill" = "1" ] && [ "$sim_fullfill" = "1" ] && [ "$netdev_fullfill" = "1" ] ;then
        at "$at_port" "AT+CFUN=1"
        return 1
    else
        return 0
    fi
}

check_ip()
{
    case $manufacturer in
            "simcom")
                case $platform in
                    "qualcomm")
                        check_ip_command="AT+CGPADDR=6"
                        ;;
                esac
                ;;
            "neoway")
                case $platform in
                    "unisoc")
                        check_ip_command="AT+CGPADDR=1"
                        ;;
                esac
                ;;
            *)
                check_ip_command="AT+CGPADDR=$pdp_index"
                ;;
        esac

        if [ "$driver" = "mtk_pcie" ]; then
            mbim_port=$(echo "$at_port" | sed 's/at/mbim/g')
            local config=$(umbim -d $mbim_port config)
            ipaddr=$(echo "$config" | grep "ipv4address:" | awk '{print $2}' | cut -d'/' -f1)
            ipaddr="$ipaddr $(echo "$config" | grep "ipv6address:" | awk '{print $2}' | cut -d'/' -f1)"
        else
            ipaddr=$(at "$at_port" "$check_ip_command" | grep +CGPADDR:)
        fi

        if [ -n "$ipaddr" ];then
            ipv6=$(echo $ipaddr | grep -oE "\b([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b")
            ipv4=$(echo $ipaddr | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | grep -v '^0\.0\.0\.0$' | head -n 1)
            if [ "$manufacturer" = "simcom" ];then
                ipv4=$(echo $ipaddr | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | grep -v "0\.0\.0\.0" | head -n 1)
                ipv6=$(echo $ipaddr | grep -oE "\b([0-9a-fA-F]{0,4}.){2,7}[0-9a-fA-F]{0,4}\b")
            fi
            # disallow_ipv4="0.0.0.0"
            # #remove the disallow ip
            # if [[ "$ipv4" == *"$disallow_ipv4"* ]];then
            #     ipv4=""
            # fi
            connection_status=0
            if [ -n "$ipv4" ];then
                connection_status=1
            fi
            if [ -n "$ipv6" ];then
                connection_status=2
            fi
            if [ -n "$ipv4" ] && [ -n "$ipv6" ];then
                connection_status=3
            fi
        else
            if [ "$driver" = "ncm" ] && [ "$manufacturer" = "fibocom" ] && [ "$platform" = "intel" ] && [ -n "$modem_netcard" ]; then
                ipv4=$(ip -4 addr show dev "$modem_netcard" 2>/dev/null | grep -oE 'inet [0-9.]+/[0-9]+' | awk '{print $2}' | cut -d/ -f1 | head -1)
                ipv6=$(ip -6 addr show dev "$modem_netcard" 2>/dev/null | grep -oE 'inet6 [0-9a-fA-F:]+/[0-9]+' | awk '{print $2}' | cut -d/ -f1 | grep -v '^fe80:' | head -1)
                if [ -n "$ipv4" ] || [ -n "$ipv6" ]; then
                    connection_status=0
                    [ -n "$ipv4" ] && connection_status=1
                    [ -n "$ipv6" ] && connection_status=2
                    [ -n "$ipv4" ] && [ -n "$ipv6" ] && connection_status=3
                    return
                fi
            fi
            connection_status="-1"
            m_debug "AT port returned an unexpected IP response: $ipaddr"
        fi
}

append_to_fw_zone()
{
    local fw_zone=$1
    local if_name=$2
    source /etc/os-release
    local os_version=${VERSION_ID:0:2}
    if [ "$os_version" -le 21 ];then
        has_ifname=0
        origin_line=$(uci -q get firewall.@zone[${fw_zone}].network)
        for i in $origin_line
        do
            if [ "$i" = "$if_name" ];then
                has_ifname=1
            fi
        done
        if [ -n "$origin_line" ] && [ "$has_ifname" -eq 0 ];then
            uci set firewall.@zone[${fw_zone}].network="${origin_line} ${if_name}"
        elif [ -z "$origin_line" ];then
            uci set firewall.@zone[${fw_zone}].network="${if_name}"
        fi
    else
        uci add_list firewall.@zone[${fw_zone}].network=${if_name}
    fi
}

set_if()
{
    firewall_reload_flag=0
    dhcp_reload_flag=0
    network_reload_flag=0
    interface_update_flag=0
    bridge_network_dirty=0
    bridge_xmodem_dirty=0
    #check if exist
    proto="dhcp"
    protov6="dhcpv6"
    case $manufacturer in
        "quectel")
            case $platform in
                "unisoc")
                    case $driver in
                        "mbim")
                            proto="none"
                            protov6="none"
                            ;;
                        esac
                    ;;
            esac
            ;; 
        "fibocom")
            case $platform in
                "mediatek")
                    proto="static"
                    protov6="dhcpv6"
                    ;;
                "intel")
                    # XMM L850/L860: v4 static (NCM via CGCONTRDP, MBIM via
                    # mbimcli). v6 via DHCPv6: odhcp6c picks up the RA-advertised
                    # global address + delegates the /64 prefix to LAN.
                    proto="static"
                    protov6="dhcpv6"
                    ;;
                esac
            ;;
    esac
    if [ "$bridge_enabled" = "1" ]; then
        proto="none"
        protov6="none"
    fi
    case $pdp_type in
        "ip")
            env4="1"
            env6="0"
            ;;
        "ipv6")
            env4="0"
            env6="1"
            ;;
        "ipv4v6")
            env4="1"
            env6="1"
            ;;
    esac
    if [ "$bridge_enabled" = "1" ]; then
        env4="1"
        env6="0"
    fi
    interface=$(uci -q get network.$interface_name)
    interfacev6=$(uci -q get network.$interface6_name)
    num=$(uci show firewall | grep "name='wan'" | wc -l)
    if [ "$env4" -eq 1 ];then
        if [ -z "$interface" ];then
            uci set network.${interface_name}=interface
            uci set network.${interface_name}.modem_config="${modem_config}"
            uci set network.${interface_name}.proto="${proto}"
            uci set network.${interface_name}.defaultroute='1'
            uci set network.${interface_name}.metric="${metric}"
            uci del network.${interface_name}.dns
            if [ -n "$dns_list" ];then
                uci set network.${interface_name}.peerdns='0'
                for dns in $dns_list;do
                    uci add_list network.${interface_name}.dns="${dns}"
                done
            else
                uci del network.${interface_name}.peerdns
            fi
            local wwan_num=$(uci -q get firewall.@zone[$num].network | grep -w "${interface_name}" | wc -l)
            if [ "$wwan_num" = "0" ]; then
                append_to_fw_zone $num ${interface_name}
            fi
            network_reload_flag=1
            firewall_reload_flag=1
            m_debug "IPv4 interface ready"
        fi
    else
        if [ -n "$interface" ];then
            uci delete network.${interface_name}
            network_reload_flag=1
            m_debug "Interface removed"
        fi
    fi
    if [ "$env6" -eq 1 ];then
        if [ -z "$interfacev6" ];then
            # uci set network.lan.ipv6='1' # user decide themself whether to enable IPv6 on LAN.
            # uci set network.lan.ip6assign='64'
            uci set network.${interface6_name}='interface'
            uci set network.${interface6_name}.modem_config="${modem_config}"
            uci set network.${interface6_name}.proto="${protov6}"
            uci set network.${interface6_name}.ifname="@${interface_name}"
            uci set network.${interface6_name}.device="@${interface_name}"
            uci set network.${interface6_name}.metric="${metric}"
            
            local wwan6_num=$(uci -q get firewall.@zone[$num].network | grep -w "${interface6_name}" | wc -l)
            if [ "$wwan6_num" = "0" ]; then
                append_to_fw_zone $num ${interface6_name}
            fi
            network_reload_flag=1
            firewall_reload_flag=1
            m_debug "IPv6 interface ready"
        fi
        if [ -n "$interfacev6" ] && [ "$(uci -q get network.${interface6_name}.proto)" != "$protov6" ];then
            uci set network.${interface6_name}.proto="${protov6}"
            network_reload_flag=1
            m_debug "update $interface6_name proto -> $protov6"
        fi
        if [ "$ra_master" = "1" ];then
            uci set dhcp.${interface6_name}='dhcp'
            uci set dhcp.${interface6_name}.interface="${interface6_name}"
            uci set dhcp.${interface6_name}.ra='relay'
            uci set dhcp.${interface6_name}.ndp='relay'
            uci set dhcp.${interface6_name}.master='1'
            uci set dhcp.${interface6_name}.ignore='1'
            uci set dhcp.lan.ra='relay'
            uci set dhcp.lan.ndp='relay'
            uci set dhcp.lan.dhcpv6='relay'
            dhcp_reload_flag=1
        elif [ "$extend_prefix" = "1" ];then
            uci set network.${interface6_name}.extendprefix=1
            dhcpv6=$(uci -q get dhcp.${interface6_name})
            if [ -n "$dhcpv6" ];then
                uci delete dhcp.${interface6_name}
                dhcp_reload_flag=1
            fi
        else
            dhcpv6=$(uci -q get dhcp.${interface6_name})
            if [ -n "$dhcpv6" ];then
                uci delete dhcp.${interface6_name}
                dhcp_reload_flag=1
            fi
        fi
    else
        if [ -n "$interfacev6" ];then
            uci delete network.${interface6_name}
            network_reload_flag=1
            dhcpv6=$(uci -q get dhcp.${interface6_name})
            if [ -n "$dhcpv6" ];then
                dhcp_reload_flag=1
            fi
            m_debug "delete interface $interface6_name"
        fi
    fi


    set_modem_netcard=$modem_netcard
    if [ -z "$set_modem_netcard" ];then
        m_debug "no netcard found"
    fi
    ethernet_check=$(handle_5gethernet)
    if [ -n "$ethernet_check" ] && [ -n "/sys/class/net/$ethernet_5g" ] && [ -n "$ethernet_5g" ];then
        set_modem_netcard=$ethernet_5g
    fi
    if [ "$bridge_enabled" = "1" ]; then
        ensure_bridge_passthrough "$set_modem_netcard"
        target_netcard="$bridge_device_name"
    else
        cleanup_bridge_passthrough
        target_netcard="$set_modem_netcard"
    fi
    [ -z "$target_netcard" ] && target_netcard="$set_modem_netcard"

    #set led
    set_led "net" $modem_config $set_modem_netcard
    origin_netcard=$(uci -q get network.$interface_name.ifname)
    origin_device=$(uci -q get network.$interface_name.device)
    origin_metric=$(uci -q get network.$interface_name.metric)
    origin_proto=$(uci -q get network.$interface_name.proto)
    if [ "$origin_netcard" == "$target_netcard" ] && [ "$origin_device" == "$target_netcard" ] && [ "$origin_metric" == "$metric" ] && [ "$origin_proto" == "$proto" ];then
        m_debug "Interface $interface_name is already bound to $target_netcard"
    else
        uci set network.${interface_name}.ifname="${target_netcard}"
        uci set network.${interface_name}.device="${target_netcard}"
        uci set network.${interface_name}.modem_config="${modem_config}"
        if [ "$env4" -eq 1 ];then
            uci set network.${interface_name}.proto="${proto}"
            uci set network.${interface_name}.metric="${metric}"
        fi
        if [ "$env6" -eq 1 ];then
            uci set network.${interface6_name}.proto="${protov6}"
            uci set network.${interface6_name}.metric="${metric}"
        fi
        interface_update_flag=1
        m_debug "Network device ready: $target_netcard"
    fi

    if [ "$bridge_xmodem_dirty" -eq 1 ]; then
        uci commit xmodem
    fi
    if [ "$network_reload_flag" -eq 1 ] || [ "$interface_update_flag" -eq 1 ] || [ "$bridge_network_dirty" -eq 1 ];then
        uci commit network
        if [ "$bridge_network_dirty" -eq 1 ]; then
            /etc/init.d/network reload
            m_debug "Network service reloaded"
        else
            ifup ${interface_name}
            ifup ${interface6_name}
            m_debug "Network service reloaded"
        fi
    fi
    if [ "$firewall_reload_flag" -eq 1 ];then
        uci commit firewall
        /etc/init.d/firewall restart
        m_debug "Firewall reloaded"
    fi
    if [ "$dhcp_reload_flag" -eq 1 ];then
        uci commit dhcp
        /etc/init.d/dhcp restart
        m_debug "DHCP reloaded"
    fi
}

flush_if()
{
    network_reload_needed=0
    xmodem_reload_needed=0
    ifdown ${interface_name} >/dev/null 2>&1
    ifdown ${interface6_name} >/dev/null 2>&1
    config_load network
    remove_target="$modem_config"
    config_foreach flush_ip_cb "interface"
    cleanup_bridge_passthrough
    [ "$bridge_network_dirty" -eq 1 ] && network_reload_needed=1
    [ "$bridge_xmodem_dirty" -eq 1 ] && xmodem_reload_needed=1
    set_led "net" $modem_config
    set_led "sim" $modem_config 0
    m_debug "Interface removed"
    uci commit network
    uci commit dhcp
    [ "$xmodem_reload_needed" -eq 1 ] && uci commit xmodem
    if [ "$network_reload_needed" -eq 1 ]; then
        /etc/init.d/network reload
    fi
}

flush_ip_cb()
{
    local network_cfg=$1
    local bind_modem_config
    config_get bind_modem_config "$network_cfg" modem_config
    if [ "$remove_target" = "$bind_modem_config" ];then
        uci delete network.$network_cfg
        network_reload_needed=1
    fi
    
}

dial(){
    update_config
    m_debug "Preparing modem: $driver, SIM slot $sim_slot"
    while [ "$dial_prepare" != 1 ] ; do
        sleep 5
        update_config
        check_dial_prepare
        dial_prepare=$?
    done
    set_if
    m_debug "Connecting via $driver"
    exec_pre_dial $modem_config
    case $driver in
        "qmi")
            qmi_dial
            ;;
        "mbim")
            mbim_dial
            ;;
        "mhi")
            mhi_dial
            ;;
        "ncm")
            at_dial_monitor
            ;;
        "ecm")
            at_dial_monitor
            ;;
        "rndis")
            at_dial_monitor
            ;;
        "mtk_pcie")
            at_dial_monitor
            ;;
        *)
            mbim_dial
            ;;
    esac
}

wwan_hang()
{
    pid=$(cat "${MODEM_RUNDIR}/${modem_config}_dir/$modem_config.pid")
    m_debug "wwan_hang, pid = $pid"
    if [ -n $pid ]; then
        kill $pid
    fi
}

ecm_hang()
{
    m_debug "Data session stopped"
    auto_dial_hang_fail=0
    auto_dial_hang
    auto_dial_hang_fail=$?
    if [ $auto_dial_hang_fail -eq 0 ]; then
        return
    fi
    case "$manufacturer" in
        "quectel")
            at_command="AT+QNETDEVCTL=$pdp_index,2,1"
            ;;
        "fibocom")
            case "$platform" in
                "mediatek")
                    at_command="AT+CGACT=0,$pdp_index"
                    ;;
                "intel")
                    at "${at_port}" "AT+XDATACHANNEL=0"
                    at_command="AT+CGDATA=0"
                    ;;
                *)
                    at_command="AT+GTRNDIS=0,$pdp_index"
                    ;;
            esac
            ;;
        "meig")
            at_command='AT$QCRMCALL=0,0,3,2,'$pdp_index
            ;;
        "huawei")
            at_command="AT^NDISDUP=0,0"
            ;;
        "neoway")
            delay=3
            at_command='AT$MYUSBNETACT=0,0'
            ;;
        "gosuncn")
            at_command="AT+ZECMCALL=0"
            ;;
        *)
            at_command="ATI"
            ;;
    esac
    at "${at_port}" "${at_command}"
    [ -n "$delay" ] && sleep "$delay"
}

auto_dial_stop(){
    m_debug "stop auto dial"
    case "$manufacturer" in
        "huawei")
        case "$platform" in
            "unisoc")
            ;;
        esac
        ;;
    esac
}


hang()
{
    m_debug "Stopping $driver connection"
    case $driver in
        "ncm")
            ecm_hang
            ;;
        "ecm")
            ecm_hang
            ;;
        "rndis")
            ecm_hang
            ;;
        "qmi")
            wwan_hang
            ;;
        "mbim")
            wwan_hang
            ;;
        "mhi")
            wwan_hang
            ;;
    esac
    flush_if
}

mbim_dial(){
    if [ -z "$apn" ];then
        apn="auto"
    fi
    # Intel XMM (L850-GL): the data session is driven by mbimcli/libmbim. quectel-CM
    # is NOT used (its MBIM data plane is incompatible with XMM; see
    # docs/L850-quectel-cm-investigation.md).
    if [ "$platform" = "intel" ] && command -v mbimcli >/dev/null 2>&1; then
        mbim_dial_intel
        return
    fi
    qmi_dial
}

# ---- MM-grade MBIM dialer (libmbim/mbimcli) --------------------------------
# Mirrors ModemManager's flow on the proven libmbim stack: readiness -> radio on
# -> wait SIM-ready+registered+attached -> connect -> tight monitor with
# seamless in-place re-IP + escalating self-healing recovery ladder.
MBIM_MON_INTERVAL=5     # connection poll seconds (MM is ~1s event-driven; 5s poll is cheap+responsive)
MBIM_READY_TRIES=30     # x2s -> up to 60s to reach SIM-ready+registered+attached

mbim_resolve_wdm()
{
    mbim_wdm="/dev/cdc-wdm0"
    [ -n "$modem_path" ] && { local w=$(find "$modem_path" -name 'cdc-wdm*' 2>/dev/null | head -1); [ -n "$w" ] && mbim_wdm="/dev/$(basename "$w")"; }
}

# $1 = mbimcli query flag, $2 = label text -> prints the 'value'
mbim_field()
{
    mbimcli -d "$mbim_wdm" -p "$1" --no-close 2>/dev/null | sed -n "s/.*$2: '\\([A-Za-z0-9-]*\\)'.*/\\1/p" | head -1
}

# wait until cdc-wdm + netdev exist and MBIM answers
mbim_wait_dev()
{
    local i=0 n="${1:-30}"
    while [ $i -lt $n ]; do
        [ -e "$mbim_wdm" ] && [ -d "/sys/class/net/$modem_netcard" ] && \
            mbimcli -d "$mbim_wdm" -p --query-device-caps --no-close >/dev/null 2>&1 && return 0
        i=$((i+1)); sleep 2
    done
    return 1
}

# MM-like gate: SIM initialized + registered (home/roaming). NOTE: do NOT wait
# for packet-service 'attached' here — the XMM L850 stays detached until the
# host issues CONNECT (CONNECT triggers the attach). Waiting for attach first
# would deadlock.
mbim_wait_ready()
{
    local i=0 n="${1:-$MBIM_READY_TRIES}" sub reg
    while [ $i -lt $n ]; do
        sub=$(mbim_field --query-subscriber-ready-status "Ready state")
        if [ "$sub" = "initialized" ]; then
            reg=$(mbim_field --query-register-state "Register state")
            case "$reg" in
                home|roaming|partner) return 0 ;;
            esac
        fi
        i=$((i+1)); sleep 2
    done
    m_debug "mbim wait_ready timeout (sub=$sub reg=$reg)"
    return 1
}

# self-healing recovery ladder (validated on L850):
#   1 = MBIM disconnect (clear stale session)
#   2 = modem reset AT+CFUN=1,1 (full re-enumerate)
#   3 = USB re-enumerate via authorized toggle (software replug)
mbim_recover()
{
    case "$1" in
        1)
            mbimcli -d "$mbim_wdm" -p --disconnect --no-close >/dev/null 2>&1; sleep 2
            ;;
        2)
            m_debug "mbim recover L2: modem reset (CFUN=1,1)"
            at "$at_port" "AT+CFUN=1,1" >/dev/null 2>&1
            mbim_resolve_wdm; mbim_wait_dev 40
            ;;
        3)
            m_debug "mbim recover L3: USB re-enumerate"
            if [ -w "${modem_path%/}/authorized" ]; then
                echo 0 > "${modem_path%/}/authorized" 2>/dev/null; sleep 4
                echo 1 > "${modem_path%/}/authorized" 2>/dev/null
            else
                ( /usr/bin/xmodem-usb-redetect once >/dev/null 2>&1 & )
            fi
            mbim_resolve_wdm; mbim_wait_dev 40
            ;;
    esac
}

mbim_dial_intel()
{
    mbim_resolve_wdm
    mbim_wait_dev 60 || m_debug "mbim device not ready, proceeding anyway"
    # ensure radio on (MM enables the modem before connecting)
    mbimcli -d "$mbim_wdm" -p --query-radio-state --no-close 2>/dev/null | grep -q "Software radio state: 'off'" && \
        mbimcli -d "$mbim_wdm" -p --set-radio-state=on --no-close >/dev/null 2>&1
    mbim_wait_ready
    mbimcli -d "$mbim_wdm" -p --disconnect --no-close >/dev/null 2>&1
    local j=0
    while [ $j -lt 3 ]; do mbim_connect_intel && break; j=$((j+1)); sleep 4; done

    # tight monitor: in-place re-IP while activated; escalating recovery when down
    local fail=0
    while true; do
        sleep "$MBIM_MON_INTERVAL"
        # Healthy only if the session is activated AND we have an IPv4 on the
        # netdev. XMM can report 'activated' with no data path; treat that as a
        # failure so the recovery ladder kicks in.
        if mbimcli -d "$mbim_wdm" -p --query-connection-state --no-close 2>/dev/null | grep -q "Activation state: 'activated'" && mbim_apply_ip; then
            fail=0
        else
            fail=$((fail+1))
            m_debug "MBIM session down (fail=$fail), recovering"
            if   [ $fail -ge 10 ]; then mbim_recover 3; fail=0
            elif [ $fail -ge 6 ];  then mbim_recover 2
            else                        mbim_recover 1
            fi
            mbim_wait_ready 15
            mbim_connect_intel
        fi
        check_logfile_line
    done
}

mbim_connect_intel()
{
    local apn_use
    apn_use="$apn"
    if [ -z "$apn_use" ] || [ "$apn_use" = "auto" ]; then
        apn_use=$(at ${at_port} "AT+CGDCONT?" | grep "+CGDCONT: $pdp_index," | head -1 | awk -F, '{print $3}' | tr -d '"\r ')
    fi
    m_debug "mbim connect apn='$apn_use' dev=$mbim_wdm"
    mbimcli -d "$mbim_wdm" -p --connect="apn=$apn_use" --no-close >/dev/null 2>&1
    mbim_apply_ip force
}

# Read the modem's current IPv4 config and (re)apply it to the netdev. Only acts
# when the address changed (or $1=force), so it also recovers from a silent
# operator re-IP (e.g. XL re-addresses every ~2h) without a full reconnect.
mbim_apply_ip()
{
    local out v4 v4ip v4gw v4dns1 v4dns2 cur dev
    local public_dns1_ipv4="223.5.5.5"
    local public_dns2_ipv4="119.29.29.29"
    out=$(mbimcli -d "$mbim_wdm" -p --query-ip-configuration --no-close 2>&1)
    v4=$(echo "$out" | sed -n '/IPv4 configuration/,/IPv6 configuration/p')
    [ -z "$v4" ] && v4=$(echo "$out" | sed -n '/IPv4 configuration/,$p')
    v4ip=$(echo "$v4" | grep "IP \[0\]:" | head -1 | awk -F"'" '{print $2}')
    echo "$v4ip" | grep -qE '^[0-9.]+/[0-9]+$' || { m_debug "mbim apply_ip: no IPv4 yet"; return 1; }
    cur=$(uci -q get network.${interface_name}.ipaddr)
    [ "$1" != "force" ] && [ "$v4ip" = "$cur" ] && return 0
    v4gw=$(echo "$v4" | grep "Gateway:" | head -1 | awk -F"'" '{print $2}')
    v4dns1=$(echo "$v4" | grep "DNS \[0\]:" | head -1 | awk -F"'" '{print $2}')
    v4dns2=$(echo "$v4" | grep "DNS \[1\]:" | head -1 | awk -F"'" '{print $2}')
    [ -z "$v4dns1" ] && v4dns1="$public_dns1_ipv4"
    [ -z "$v4dns2" ] && v4dns2="$public_dns2_ipv4"
    uci set network.${interface_name}.proto='static'
    uci set network.${interface_name}.ipaddr="${v4ip}"
    [ -n "$v4gw" ] && uci set network.${interface_name}.gateway="${v4gw}"
    uci set network.${interface_name}.peerdns='0'
    uci -q del network.${interface_name}.dns
    uci add_list network.${interface_name}.dns="${v4dns1}"
    uci add_list network.${interface_name}.dns="${v4dns2}"
    uci commit network
    dev=$(uci -q get network.${interface_name}.device); [ -z "$dev" ] && dev="$modem_netcard"
    if [ "$1" = "force" ]; then
        # initial bring-up: let netifd configure route/firewall/DNS
        ifup ${interface_name}
    else
        # re-IP (operator changed address): seamless in-place swap, no teardown
        local mtr=$(uci -q get network.${interface_name}.metric)
        local a
        ip -4 addr add "$v4ip" dev "$dev" 2>/dev/null
        for a in $(ip -4 addr show dev "$dev" 2>/dev/null | grep -oE 'inet [0-9.]+/[0-9]+' | awk '{print $2}'); do
            [ "$a" != "$v4ip" ] && ip -4 addr del "$a" dev "$dev" 2>/dev/null
        done
        [ -n "$v4gw" ] && ip -4 route replace default via "$v4gw" dev "$dev" metric "${mtr:-11}" 2>/dev/null
    fi
    [ -n "$dev" ] && ip link set dev "$dev" arp off 2>/dev/null
    m_debug "mbim ip ${cur:-none} -> $v4ip gw $v4gw ($1)"
}

mhi_dial()
{
    qmi_dial
}

qmi_dial()
{
    cmd_line="quectel-CM"
    [ -e "/usr/bin/quectel-CM-M" ] && cmd_line="quectel-CM-M" && tom_modified=1
    case $pdp_type in
        "ip") cmd_line="$cmd_line -4" ;;
        "ipv6") cmd_line="$cmd_line -6" ;;
        "ipv4v6") cmd_line="$cmd_line -4 -6" ;;
        *) cmd_line="$cmd_line -4 -6" ;;
    esac

    if [ -n "$pdp_index" ] && [ "$userset_pdp_index" = "1" ]; then
        cmd_line="$cmd_line -n $pdp_index"
    fi
    if [ "$manufacturer" = "telit" ] && [ "$force_set_apn" != "1" ];then
        m_debug 'please use force apn set for telit modem'
    fi
    if [ -n "$apn" ]; then
        cmd_line="$cmd_line -s $apn"
    fi
    if [ -n "$username" ]; then
        cmd_line="$cmd_line $username"
    fi
    if [ -n "$password" ]; then
        cmd_line="$cmd_line $password"
    fi
    if [ "$auth" != "none" ]; then
        cmd_line="$cmd_line $auth"
    fi
    if [ -n "$modem_netcard" ]; then
    qmi_if=$modem_netcard
    #if is wwan* ,use the first part of the name
    if  [[ "$modem_netcard" = "wwan"* ]];then
        qmi_if=$(echo "$modem_netcard" | cut -d_ -f1)
    fi
    #if is rmnet* ,use the first part of the name
    if [[ "$modem_netcard" = "rmnet"* ]];then
        qmi_if=$(echo "$modem_netcard" | cut -d. -f1)
    fi
        cmd_line="${cmd_line} -i ${qmi_if}"
    fi
    if [ "$bridge_enabled" = "1" ];then
        cmd_line="${cmd_line} -b"
    fi
    if [ "$do_not_add_dns" = "1" ];then
        cmd_line="${cmd_line} -D"
    fi
    if [ -e "/usr/bin/quectel-CM-M" ];then
        [ -n "$metric" ] && cmd_line="$cmd_line -d -M $metric"
        [ "$force_set_apn" == "1" ] && cmd_line="$cmd_line -F"
    else
        [ -n "$metric" ] && cmd_line="$cmd_line"
    fi
    cmd_line="$cmd_line -f $log_file"
    while true; do
        m_debug "dialing: $cmd_line"
        $cmd_line &
        echo "$!" > "${MODEM_RUNDIR}/${modem_config}_dir/$modem_config.pid"
        m_debug "pid: $!"
        wait
        m_debug "quectel-CM exited, retrying dial"
    done
}

wait_cereg()
{
    # after a modem reset the radio is still re-registering; wait until CEREG
    # reports registered (1=home,5=roaming) before activating data, so the dialer
    # does not hammer an unregistered modem (which left it stuck at COPS=2)
    local i=0 st
    while [ $i -lt 20 ]; do
        st=$(at "$at_port" "AT+CEREG?" | tr -d '\r' | sed -n 's/.*+CEREG: [0-9],\([0-9]\).*/\1/p' | head -1)
        case "$st" in 1|5) return 0 ;; esac
        i=$((i+1)); sleep 2
    done
    return 1
}

at_dial()
{
    if [ -z "$pdp_type" ];then
        pdp_type="IP"
    fi
    [ -n "$apn" ] && apn_append=",\"$apn\"" || apn_append=""
    local at_command='AT+COPS=0,0'
    tmp=$(at "${at_port}" "${at_command}")
    [ "$platform" = "intel" ] && wait_cereg
    pdp_type=$(echo $pdp_type | tr 'a-z' 'A-Z')
    case $manufacturer in
        "quectel")
            [ "$donot_nat" = "1" ] && nat_cfg="AT+QCFG=\"nat\",0" || nat_cfg="AT+QCFG=\"nat\",1"
            case $platform in
                "hisilicon")
                    at_command="AT+QNETDEVCTL=1,1,1"
                    cgdcont_command=""
                    ;;

                "unisoc")
                    at_command="AT+QNETDEVCTL=1,$pdp_index,1" # +QNETDEVCTL: <cid>,<op>,<state> 
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
                *)
                    at_command="AT+QNETDEVCTL=3,$pdp_index,1" #LTE Standard AT+QNETDEVCTL=<connect_type>[,<CID>[,<URC_switch>]] 
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "fibocom")
            case $platform in
                "intel")
                    # Fibocom L850/L860-GL (XMM7360) NCM: RAW-IP over CDC-NCM (ref: mrhaav atc)
                    # idempotent init: enable dynamic DNS + IPv6 address format
                    at "${at_port}" "AT+XDNS=0,1;+XDNS=0,2"
                    at "${at_port}" "AT+CGPIAF=1,1,0,1"
                    # order sent by generic dialer: cgdcont -> ppp_auth -> nat_cfg -> at_command
                    cgdcont_command="AT+CGDCONT=0,\"$pdp_type\"$apn_append"
                    if [ -n "$auth" ] && [ -n "$username" ]; then
                        case $auth in
                            "pap") auth_num=1 ;;
                            "chap") auth_num=2 ;;
                            *) auth_num=2 ;;
                        esac
                        ppp_auth_command="AT+XGAUTH=0,$auth_num,\"$username\",\"$password\""
                    fi
                    nat_cfg="AT+XDATACHANNEL=1,1,\"/USBCDC/0\",\"/USBHS/NCM/0\",2,0"
                    at_command="AT+CGDATA=\"M-RAW_IP\",0"
                    ;;
                "mediatek")
                    # delay=3
                    # [ "$apn" = "auto" ] || [ -z "$apn" ] && apn="cbnet"
                    if [ "$pdp_index" = "3" ];then
                        delay=3
                        [ "$apn" = "auto" ] || [ -z "$apn" ] && apn="cbnet"
                        m_debug "Due to a historical issue (https://github.com/FUjr/XModem/issues/179#issuecomment-3968653343), the fm350 pdp_index was incorrectly set to 3, which caused dialing to work but remain unstable. In version 2026.2.27, we have fixed this issue."
                        m_debug "To avoid unexpectedly removing legacy configuration files, we applied additional handling to ensure consistent behavior with previous versions. However, if you see this message, please manually set the pdp_index to 0. We apologize for any inconvenience caused."
                    fi
                    at_command="AT+CGACT=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\",\"$apn\""
                    ;;
                "lte")
                    at_command="AT+GTRNDIS=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    if [ -n "$auth" ]; then
                        case $auth in
                            "pap") 
                                auth_num=1 ;;
                            "chap") 
                                auth_num=2 ;;
                            "auto"|"both"|"MsChapV2") 
                                auth_num=3 ;;
                            *) 
                                auth_num=0 ;;
                        esac
                        if [ -n "$username" ] || [ -n "$password" ] && [ "$auth_num" != "0" ] ; then
                            ppp_auth_command="AT+MGAUTH=$pdp_index,$auth_num,\"$username\",\"$password\""
                        fi
                    fi
                    ;;
                "unisoc")
                    at_command="AT+GTRNDIS=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    if [ -n "$auth" ]; then
                        case $auth in
                            "pap") 
                                auth_num=1 ;;
                            "chap") 
                                auth_num=2 ;;
                            "auto"|"both"|"MsChapV2") 
                                auth_num=3 ;;
                            *) 
                                auth_num=0 ;;
                        esac
                        if [ -n "$username" ] || [ -n "$password" ] && [ "$auth_num" != "0" ] ; then
                            ppp_auth_command="AT+MGAUTH=$pdp_index,$auth_num,\"$username\",\"$password\""
                        fi
                    fi
            esac
            ;;
        "huawei")
            case $platform in
                "hisilicon")
                    at_command="AT^NDISDUP=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    if [ -n "$auth" ]; then
                        case $auth in
                            "pap") 
                                auth_num=1 ;;
                            "chap") 
                                auth_num=2 ;;
                            "auto"|"both"|"MsChapV2") 
                                auth_num=3 ;;
                            *) 
                                auth_num=0 ;;
                        esac
                        if [ -n "$username" ] || [ -n "$password" ] && [ "$auth_num" != "0" ] ; then
                            plmn=$(at ${at_port} "AT+COPS=3,2;+COPS?" | grep "+COPS:" | sed 's/+COPS: //g' | cut -d',' -f3 | sed 's/\"//g' | cut -c1-5 | grep -o  -o '[0-9]\{5\}')
                            [ -z "$plmn" ] && plmn="00000"
                            ppp_auth_command="AT^AUTHDATA=$pdp_index,$auth_num,$plmn,\"$username\",\"$password\""
                        fi
                    fi
                    ;;
            esac
            ;;
        "simcom")
            case $platform in
                "asrmicro")                    
                    at_command="AT+CGACT=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
                "qualcomm")
                    local cnmp=$(at ${at_port} "AT+CNMP?" | grep "+CNMP:" | sed 's/+CNMP: //g' | sed 's/\r//g')
                    at_command="AT+CNMP=$cnmp;+CNWINFO=1"
                    cgdcont_command="AT+CGDCONT=1,\"$pdp_type\""$apn_append
                    ;;
                "lte")
                    at_command="AT+CGACT=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "meig")
            case $platform in
                "qualcomm")
                    at_command='AT$QCRMCALL=1,0,3,2,'$pdp_index
                    cgdcont_command="AT+CGDCONT=1,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "neoway")
            case $platform in
                "unisoc")
                    at_command='AT$MYUSBNETACT=0,1'
                    cgdcont_command="AT+CGDCONT=1,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "telit")
            case $platform in
                "qualcomm")
                    at_command="AT#ICMAUTOCONN=1,$pdp_index"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
        "gosuncn")
            case $platform in
                "lte")
                    at_command="AT+ZECMCALL=1"
                    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\""$apn_append
                    ;;
            esac
            ;;
    esac
	m_debug "Dial command sent"
    m_debug "Connection profile applied"
	case $driver in
        "mtk_pcie")
            mbim_port=$(echo "$at_port" | sed 's/at/mbim/g')
            [ -n "$apn" ] || apn="auto"
        	rf_status=$(umbim -d  $mbim_port radio|sed -n 's/.*swradiostate: *//p')
        	[ "$rf_status" = "off" ] && umbim -d  $mbim_port radio on
        	umbim -d $mbim_port disconnect
        	sleep 1
        	umbim -d $mbim_port connect 0 --apn $apn
		 	;;
		*)
  			at "${at_port}" "${cgdcont_command}"
            [ -n "$ppp_auth_command" ] && at "${at_port}" "$ppp_auth_command"
            [ -n "$nat_cfg" ] && at "${at_port}" "$nat_cfg"
        	at "${at_port}" "$at_command"
		 	;;
	esac
}

at_auto_dial()
{
    case $manufacturer in
        "huawei")
            case $platform in
                "unisoc")
                    huawei_auto_dial_unisoc
                    return 0
                    ;;
            esac
            ;;
    esac
    return 1
}

huawei_auto_dial_unisoc()
{
    m_debug "huawei_auto_dial: auto dial(no monitor)"
    m_debug "huawei_auto_dial: vendor:$manufacturer; platform:$platform; driver:$driver; apn:$apn; command:$at_command; pdp_index:$pdp_index; huawei_dial_mode:$huawei_dial_mode; at_port:$at_port"
    # dial prepare
    cgdcont_command="AT+CGDCONT=$pdp_index,\"$pdp_type\",\"$apn\""
    at "$at_port" "$cgdcont_command"
    # get current auto dial setting
    at_command='AT^SETAUTODIAL?'
    at_res=$(at "$at_port" "$at_command" | grep 'SETAUTO')
    # return ^SETAUTODAIL:1,x
    current_setting=${at_res##*:}
    dial_status=$(echo "$current_setting" | cut -d ',' -f 1)
    current_dial_mode=$(echo "$current_setting" | cut -d ',' -f 2)
    m_debug "current dial status: $dial_status, current dial mode: $current_dial_mode"
    # if dial stat is disabled, or when huawei_dial_mode is not empty and current dial mode is not equal to huawei_dial_mode, enable dial
    if [ "$dial_status" = "0" ] || [ ! -z "$huawei_dial_mode" ] && [ "$current_dial_mode" != "$huawei_dial_mode" ]; then
        [ -n "$huawei_dial_mode" ] && dial_mode=",$huawei_dial_mode" || dial_mode=",4"
        at_command="AT^SETAUTODIAL=1$dial_mode"
        at "$at_port" "$at_command"
    fi
}

auto_dial_hang_huawei_unisoc()
{
    m_debug "huawei_auto_hang"
    at_command='AT^SETAUTODIAL?'
    current_setting=$(at "$at_port" "$at_command" | grep 'SETAUTO')
    # return ^SETAUTODAIL:1,x
    current_setting=${current_setting##*:}
    dial_status=$(echo "$current_setting" | cut -d ',' -f 1)
    if [ "$dial_status" = "1" ]; then 
        at_command="AT^SETAUTODIAL=0"
        at "$at_port" "$at_command"
        m_debug "huawei_at_hang: auto hang done"
        m_debug "huawei_at_hang: turning radio off"
        off_cmd="AT+CFUN=0"
        on_cmd="AT+CFUN=1"
        at "$at_port" "$off_cmd"
        m_debug "huawei_at_hang: turning radio on"
        at "$at_port" "$on_cmd"
        return 0
    fi
    return 1
}

auto_dial_hang(){
    m_debug "Auto-dial stopped"
    case "$manufacturer" in 
        "huawei")
            case "$platform" in
                "unisoc")
                    auto_dial_hang_huawei_unisoc
                    return $?
                    ;;
            esac
            ;;
    esac
    return 1
}

subnet_calc_l850() {
    # Derive point-to-point /3x subnet + peer gateway from XMM RAW-IP address (ref: mrhaav atc)
    local A B C D x y netaddr res subnet gateway
    A=$(echo "$1" | awk -F. '{print $1}')
    B=$(echo "$1" | awk -F. '{print $2}')
    C=$(echo "$1" | awk -F. '{print $3}')
    D=$(echo "$1" | awk -F. '{print $4}')
    x=1; y=4; netaddr=$((y-1)); res=$((D%y))
    while [ $res -eq 0 ] || [ $res -eq $netaddr ]; do
        x=$((x+1)); y=$((y*2)); netaddr=$((y-1)); res=$((D%y))
    done
    subnet=$((31-x)); gateway=$((D/y))
    [ $res -eq 1 ] && gateway=$((gateway*y+2)) || gateway=$((gateway*y+1))
    echo "$subnet $A.$B.$C.$gateway"
}

ip_change_l850()
{
    local force="$1"
    local refresh_mode="${force:-fast reconnect}"
    m_debug "Refreshing IP (${refresh_mode})"
    local public_dns1_ipv4="223.5.5.5"
    local public_dns2_ipv4="119.29.29.29"
    local rdp v4addr v4prefix v4gw v4dns1 v4dns2 sc i
    # +CGCONTRDP: <cid>,<bid>,<apn>,<local_addr.mask>,<gw>,<dns1>,<dns2>,...
    # Some USB hosts expose the L850 data session a few seconds before CGCONTRDP is
    # ready. Retry so first bring-up does not cache the new IP without applying it.
    for i in 1 2 3 4 5; do
        rdp=$(at ${at_port} "AT+CGCONTRDP=$pdp_index" | grep "+CGCONTRDP:" | head -1 | sed 's/\r//g')
        v4addr=$(echo "$rdp" | awk -F, '{print $4}' | sed 's/"//g' | awk -F. '{print $1"."$2"."$3"."$4}')
        echo "$v4addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && break
        m_debug "CGCONTRDP not ready (${i}/5)"
        sleep 2
    done
    if ! echo "$v4addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        local paddr last_octet peer_octet
        v4addr="$ipv4"
        if ! echo "$v4addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            paddr=$(at ${at_port} "AT+CGPADDR=$pdp_index" | grep "+CGPADDR:" | head -1 | sed 's/\r//g')
            v4addr=$(echo "$paddr" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | grep -v '^0\.0\.0\.0$' | head -1)
        fi
        if echo "$v4addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            last_octet=$(echo "$v4addr" | awk -F. '{print $4}')
            if [ "$last_octet" -gt 0 ] && [ "$last_octet" -lt 255 ] 2>/dev/null; then
                if [ $((last_octet % 2)) -eq 0 ]; then
                    peer_octet=$((last_octet + 1))
                else
                    peer_octet=$((last_octet - 1))
                fi
                v4gw=$(echo "$v4addr" | awk -F. -v d="$peer_octet" '{print $1"."$2"."$3"."d}')
                v4prefix=31
                v4dns1="$public_dns1_ipv4"
                v4dns2="$public_dns2_ipv4"
                m_debug "CGCONTRDP unavailable; using CGPADDR fallback: $v4addr/$v4prefix via $v4gw"
            fi
        fi
        echo "$v4addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    fi
    v4dns1=$(echo "$rdp" | awk -F, '{print $6}' | sed 's/"//g' | tr -d ' ')
    v4dns2=$(echo "$rdp" | awk -F, '{print $7}' | sed 's/"//g' | tr -d ' ')
    # gateway: prefer real value from CGCONTRDP field 5 (verified on L850 live); else derive (mrhaav)
    [ -z "$v4gw" ] && v4gw=$(echo "$rdp" | awk -F, '{print $5}' | sed 's/"//g' | tr -d ' ')
    if [ -n "$v4prefix" ] && echo "$v4gw" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        :
    elif echo "$v4gw" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && [ "$v4gw" != "0.0.0.0" ]; then
        # start at /31 (RFC3021 p2p pair) so an adjacent gw (e.g. .74/.75) is a
        # valid host, not the /30 broadcast (which makes netifd drop the default route)
        v4prefix=$(awk -v a="$v4addr" -v b="$v4gw" 'function i(s,A){split(s,A,".");return A[1]*16777216+A[2]*65536+A[3]*256+A[4]} BEGIN{x=i(a);y=i(b);for(p=31;p>=8;p--){d=2^(32-p);if(int(x/d)==int(y/d)){print p;exit}}print 31}')
    else
        sc=$(subnet_calc_l850 "$v4addr")
        v4prefix=$(echo "$sc" | awk '{print $1}')
        v4gw=$(echo "$sc" | awk '{print $2}')
    fi
    [ -z "$v4dns1" ] && v4dns1="$public_dns1_ipv4"
    [ -z "$v4dns2" ] && v4dns2="$public_dns2_ipv4"
    uci set network.${interface_name}.proto='static'
    uci set network.${interface_name}.ipaddr="${v4addr}/${v4prefix}"
    uci set network.${interface_name}.gateway="${v4gw}"
    uci set network.${interface_name}.peerdns='0'
    uci -q del network.${interface_name}.dns
    uci add_list network.${interface_name}.dns="${v4dns1}"
    uci add_list network.${interface_name}.dns="${v4dns2}"
    uci commit network
    local dev=$(uci -q get network.${interface_name}.device)
    [ -z "$dev" ] && dev="$modem_netcard"
    if [ "$refresh_mode" = "force" ]; then
        ifup ${interface_name}
    else
        refresh_mode="fast-redial"
        m_debug "IP changed; reconnecting now"
        ifdown ${interface_name} >/dev/null 2>&1
        ifup ${interface_name}
        ecm_hang
        sleep 1
        at_dial
        refresh_mode="fast-redial-done"
    fi
    [ -n "$dev" ] && ip link set dev "$dev" arp off 2>/dev/null
    m_debug "Internet settings applied: $v4addr/$v4prefix via $v4gw"
}

ip_change_fm350()
{
    m_debug "ip_change_fm350"
    local public_dns1_ipv4="223.5.5.5"
    local public_dns2_ipv4="119.29.29.29"
    local netmask="255.255.255.0"

    if [ "$driver" = "mtk_pcie" ]; then
        mbim_port=$(echo "$at_port" | sed 's/at/mbim/g')

        local config=$(umbim -d $mbim_port config)
        ipv4_config=$(echo "$config" | grep "ipv4address:" | awk '{print $2}' | cut -d'/' -f1)
        gateway=$(echo "$config" | grep "ipv4gateway:" | awk '{print $2}')

        ipv4_dns1=$(echo "$config" | grep "ipv4dnsserver:" | head -n 1 | awk '{print $2}')
        ipv4_dns2=$(echo "$config" | grep "ipv4dnsserver:" | tail -n 1 | awk '{print $2}')
        [ -z "$ipv4_dns1" ] && ipv4_dns1="$public_dns1_ipv4"
        [ -z "$ipv4_dns2" ] && ipv4_dns2="$public_dns2_ipv4"
        # m_debug "umbim config: ipv4=$ipv4_config, gateway=$gateway, netmask=$netmask, dns1=$ipv4_dns1, dns2=$ipv4_dns2"
    else
        at_command="AT+CGPADDR=$pdp_index"
        response=$(at ${at_port} ${at_command})
        ipv4_config=$(echo "$response" | grep "+CGPADDR:" | grep -o '"[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+"' | head -1 | tr -d '"')
        gateway="${ipv4_config%.*}.1"

        response=$(at ${at_port} "AT+GTDNS=$pdp_index")
        ipv4_dns=$(echo "$response" | grep "+GTDNS:" | head -1)
        ipv4_dns1=$(echo "$ipv4_dns" | grep -o '"[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+"' | head -1 | tr -d '"')
        ipv4_dns2=$(echo "$ipv4_dns" | grep -o '"[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+"' | tail -1 | tr -d '"')
        [ -z "$ipv4_dns1" ] && ipv4_dns1="$public_dns1_ipv4"
        [ -z "$ipv4_dns2" ] && ipv4_dns2="$public_dns2_ipv4"
        uci_ipv4=$(uci -q get network.$interface_name.ipaddr)
    fi
    uci set network.${interface_name}.proto='static'
    uci set network.${interface_name}.ipaddr="${ipv4_config}"
    uci set network.${interface_name}.netmask="${netmask}"
    uci set network.${interface_name}.gateway="${gateway}"
    uci set network.${interface_name}.peerdns='0'
    uci -q del network.${interface_name}.dns
    uci add_list network.${interface_name}.dns="${ipv4_dns1}"
    uci add_list network.${interface_name}.dns="${ipv4_dns2}"
    uci commit network
    ifdown ${interface_name}
    ifup ${interface_name}
    m_debug "set interface $interface_name to $ipv4_config"

}

handle_5gethernet()
{
    case $manufacturer in
        "quectel")
            case $platform in
                "qualcomm")
                    quectel_qualcomm_ethernet
                    ;;
                "unisoc")
                    quectel_unisoc_ethernet
                    ;;
            esac
            ;;
    esac
}

quectel_unisoc_ethernet()
{
    case "$driver" in
        "ncm"|\
        "ecm"|\
        "rndis")
            check_ethernet_cmd="AT+QCFG=\"ethernet\""
            time=0
            while [ $time -lt 5 ]; do
                result=$(at $at_port $check_ethernet_cmd | grep "+QCFG:")
                if [ -n "$result" ]; then
                    if [ -n "$(echo $result | grep "ethernet\",1")" ]; then
                        echo "1"
                        m_debug "5G Ethernet mode is enabled"
                        break
                    fi
                fi
                sleep 5
                time=$((time+1))
            done
        ;;
    esac
}

quectel_qualcomm_ethernet()
{
     case "$driver" in
        "mbim")
            eth_driver_at="AT+QETH=\"eth_driver\""
            data_interface_at="AT+QCFG=\"data_interface\""
            ehter_driver_expect="\"r8125\",1"
            data_interface_expect="\"data_interface\",1"

            time=0
            while [ $time -lt 5 ]; do
                eth_driver_result=$(at $at_port $eth_driver_at | grep "+QETH:")
                time=$(($time+1))
                sleep 1
                if [ -n "$eth_driver_result" ];then
                    break
                fi
            done
            time=0
            while [ $time -lt 5 ]; do
                data_interface_result=$(at $at_port $data_interface_at | grep "+QCFG:")
                time=$(($time+1))
                sleep 1
                if [ -n "$data_interface_result" ];then
                    break
                fi
            done
            eth_driver_pass=$(echo $eth_driver_result | grep "$ehter_driver_expect")
            data_interface_pass=$(echo $data_interface_result | grep "$data_interface_expect")
            if  [ -n "$eth_driver_pass" ] && [ -n "$data_interface_pass" ];then
                echo "1"
                m_debug "5G Ethernet mode is enabled"
            fi
            ;;
    esac
}

handle_ip_change()
{
    export ipv4
    export ipv6
    export connection_status
    m_debug  "IP changed: ${ipv4_cache:-none} -> ${ipv4:-none}"
    case $manufacturer in
        "fibocom")
            case $platform in
                "mediatek")
                    ip_change_fm350
                    ;;
                "intel")
                    ip_change_l850 "$1"
                    ;;
            esac
            ;;
    esac
}

check_cfun(){
    at_command="AT+CFUN?"
    response=$(at ${at_port} "${at_command}")
    cfun_status=$(echo "$response" | tr -d "\r" | grep "+CFUN:" | awk '{print $2}')
    cfun_status=$(echo "$cfun_status" | cut -d',' -f1)
    if [ "$cfun_status" = "1" ]; then
        return 0
    else
        at_command="AT+CFUN=1"
        response=$(at ${at_port} "${at_command}")
        return 1
    fi
}

check_logfile_line()
{
    local line=$(wc -l $log_file | awk '{print $1}')
    if [ $line -gt 300 ];then
        echo "" > $log_file
        m_debug  "log file line is over 300,clear it"
    fi
}

unexpected_response_count=0
ncm_probe_fail_count=0
at_dial_monitor()
{
    local unexpected_retry_limit=3
    local unexpected_retry_sleep=5
    if [ "$driver" = "ncm" ] && [ "$manufacturer" = "fibocom" ] && [ "$platform" = "intel" ]; then
        unexpected_retry_limit=3
        unexpected_retry_sleep=5
    fi
    #check if support auto dial
    check_cfun
    if [ $? -ne 0 ]; then
        m_debug "CFUN is not 1, try to set it to 1"
        sleep 5
        check_cfun
        if [ $? -ne 0 ]; then
            m_debug "Failed to set CFUN to 1, dailing may not work properly"
        else
            m_debug "Successfully set CFUN to 1"
        fi
    fi
    auto_dial_support=0
    at_auto_dial
    auto_dial_support=$?
    if [ $auto_dial_support -eq 0 ]; then
        m_debug "dialing service is managed by modem(auto dial), do not need monitor"
        while true; do
            sleep 30
        done
    fi
    at_dial
    ipv4_cache=$ipv4
    ipv6_cache=$ipv6
    hang_count=0
    sleep 5
    while true; do
        check_ip
        if [ "$connection_status" -gt 0 ]; then
            hang_count=0
        else
            hang_count=$((hang_count+1))
            # modem still enumerated on USB but no connectivity for a long time
            # (hung firmware): re-enumerate via dwc3 rebind as a last resort
            if [ "$hang_count" -ge 15 ]; then
                m_debug "no IP for a long time, modem may be hung; forcing USB re-detect"
                ( /usr/bin/xmodem-usb-redetect >/dev/null 2>&1 & )
                hang_count=0
                sleep 20
            fi
        fi
        case $connection_status in
            0)
                unexpected_response_count=0
                at_dial
                sleep 3
                ;;
            -1)
                unexpected_response_count=$((unexpected_response_count+1))
                if [ $unexpected_response_count -ge $unexpected_retry_limit ]; then
                    m_debug "Modem response issue; redialing"
                    at_dial
                    unexpected_response_count=0
                fi
                sleep "$unexpected_retry_sleep"
                ;;
            *)
                unexpected_response_count=0
                if [ "$ipv4" != "$ipv4_cache" ] || [ "$ipv6" != "$ipv6_cache" ]; then
                    if [ -z "$ipv4_cache" ] && [ -z "$ipv6_cache" ]; then
                        handle_ip_change force
                        ip_change_status=$?
                    else
                        handle_ip_change
                        ip_change_status=$?
                    fi
                    if [ "$ip_change_status" -eq 0 ]; then
                        ipv4_cache=$ipv4
                        ipv6_cache=$ipv6
                    else
                        m_debug "IP refresh not ready; will retry"
                    fi
                fi


                pdp_type=$(echo $pdp_type | tr 'A-Z' 'a-z')
                if [ "$pdp_type" = "ipv4v6" ]; then
                    local ifup_time=$(ubus call network.interface.$interface6_name status 2>/dev/null | jsonfilter -e '@.uptime' 2>/dev/null || echo 0)
                    local origin_device=$(uci -q get network.$interface_name.device 2>/dev/null || echo "")
                    [ "$ifup_time" -lt 5 ] && continue
                    rdisc6 $origin_device &
                    ndisc6 fe80::1 $origin_device &
                fi
                sleep 10
                ;;
        esac
        check_logfile_line
    done
}

case "$2" in
    "hang")
        debug_subject="modem_hang"
        update_config
        hang;;
    "dial")
        case "$state" in
            "disabled")
                debug_subject="modem_hang"
                hang;;
            *)
                dial;;
        esac
esac
