#!/bin/bash

function get_dns_server {
    if [ -f /etc/resolv.conf ]; then
        echo "From /etc/resolv.conf:"
        grep -E "^nameserver" /etc/resolv.conf | while read -r line; do
            echo "	-$line"
        done
    fi

    # this one doesn't work properly
    if command -v sudo service &>/dev/null; then
        echo "From systemd-resolve:"
        sudo service systemd-resolved status | grep -E "DNS Servers|Current DNS Server|DNS server" | while read -r line; do
            echo "	-$line"
        done
    fi

    #we use nmcli if available
    if command -v nmcli &>/dev/null; then
        echo "From NetworkManager:"
        nmcli device show | grep -E "^IP4.DNS" | while read -r line; do
            echo "	-$line"
        done
    fi

    # we use resolvectl if available
    if command -v resolvectl &>/dev/null; then
        echo "From controller service :"
        resolvectl status | grep -E "DNS Servers|Current DNS Server" | head -5 | while read -r line; do
            echo "	-$line"
        done
    fi

    echo
}

function check_dns_resolution {
    local domain="www.google.com"
    if false; then
        echo "Testing DNS resolution for $domain..."
    fi
    if host $domain &>/dev/null || nslookup $domain &>/dev/null || dig $domain +short &>/dev/null; then
        log_message "DNS resolution successful for $domain"
    else
        log_message "DNS resolution failed for $domain"
    fi
}
get_dns_server
