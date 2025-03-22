#!/bin/bash
VERSION=$1
old=$2
[[ -z "${VERSION}" ]] || [[ -z "${old}" ]] && exit 1
apt install -y libapache2-mod-php${VERSION} php${VERSION} php${VERSION}-cli php${VERSION}-common php${VERSION}-curl php${VERSION}-dev php${VERSION}-fpm php${VERSION}-gd php${VERSION}-igbinary php${VERSION}-imagick php${VERSION}-intl php${VERSION}-mbstring php${VERSION}-mysql php${VERSION}-opcache php${VERSION}-readline php${VERSION}-redis php${VERSION}-xml php${VERSION}-zip php${VERSION}-soap  php${VERSION}-bcmath php${VERSION}-gmp
[[ $? -ne 0 ]] && exit 2
a2dismod php${old}
a2enmod php${VERSION}

sudo update-alternatives --set php /usr/bin/php${VERSION} 
sudo update-alternatives --set phar /usr/bin/phar${VERSION} 
sudo update-alternatives --set phar.phar /usr/bin/phar.phar${VERSION} 
sudo update-alternatives --set phpize /usr/bin/phpize${VERSION} 
sudo update-alternatives --set php-config /usr/bin/php-config${VERSION}
