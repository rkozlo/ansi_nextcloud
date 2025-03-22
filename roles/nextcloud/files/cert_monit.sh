#!/bin/bash
# Monitor certificate ans send notification to nextcloud user
DOMAIN=$1
PEM="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
NCUSER=$2
# Days threshold
DAYS=14
SEC=86400
THRR=$(( $DAYS * $SEC ))
message="Your certificate for $DOMAIN will expire in "
[[ ! -f "$PEM" ]] && echo "Pem file not found!" && exit
[[ -z "$NCUSER" ]] && echo "Pass username to announce" && exit
expire_at=$(date -d "`/usr/bin/openssl x509 -enddate -noout -in "$PEM" | sed 's/notAfter=//g'`" "+%s")
remain="$(( $expire_at - `date "+%s"` ))"
if [[ `date "+%s"` -ge $(( $expire_at - $THRR )) ]]; then
    message+=`echo $remain | awk '{printf "%d days %d hours %d minutes %d seconds\n", $1/86400, ($1%86400)/3600, ($1%3600)/60, $1%60}'`
    sudo -u www-data php /var/www/nextcloud/occ notification:generate $NCUSER "Certificate expiration" -l "$message"
fi
