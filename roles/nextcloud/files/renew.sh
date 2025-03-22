#!/usr/bin/bash
echo "Backing up crontab"
cp -f /etc/crontab /etc/crontab.backup
echo "Autoreload firewall disabled"
sed -i 's/^\(.*iptables-restore.*\)/#\1/g' /etc/crontab
echo "Opening up ports for renewal"
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sleep 5
echo "Renew try"
certbot renew;
status="$?"
[[ -z "$status" ]] || [[ "$status" == 0 ]] && echo -e "\e[32mOK\e[0m" || echo -e "\e[31mERROR\e[0m"
echo "Turning on all rules on firewall"
sed -i 's/^#\(.*iptables-restore.*\)/\1/g' /etc/crontab
