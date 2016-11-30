#!/bin/sh

# external variables
DRY_RUN=${DRY_RUN+true}
OWNER_DOMAIN=${OWNER_DOMAIN:?should be specified!}
OWNER_EMAIL=${OWNER_EMAIL:?should be specified!}

# paths
SSL_PATH="/etc/nginx/ssl"
CONFD_PATH="/etc/nginx/conf.d/services"
WEBROOT_PATH="/usr/share/nginx/html"
CERT_PATH="$SSL_PATH"/"cert.pem"
KEY_PATH="$SSL_PATH"/"key.pem"

# restrictions
UPDATE_BEFORE=7


CheckRequiredFilesAndFolders()
{
    if [ ! -d "$SSL_PATH" ]; then
        echo "$SSL_PATH should be created in Dockerfile"
        exit 1
    fi
    if [ ! -d "$CONFD_PATH" ]; then
        echo "$CONFD_PATH should be created in Dockerfile"
        exit 1
    fi
    if [ ! "$(ls -A $CONFD_PATH)" ]; then
        echo "$CONFD_PATH should contain at least one config"
        exit 1
    fi
    local sslFiles=0
    [ -f "$CERT_PATH" ] && sslFiles=$((sslFiles + 1))
    [ -f "$KEY_PATH" ] && sslFiles=$((sslFiles + 1))
    if [ "$sslFiles" == 1 ]; then
        echo "SSL files mistmatch"
        exit 1
    fi
}

MakeDhparams()
{
    local path="$1"
    local dhparams="dhparams.pem"
    if [ ! -f "$path"/"$dhparams" ]; then
        cd "$path"
        openssl dhparam -out "$dhparams" $([ "$DRY_RUN" ] && echo "512" || echo "2048")
        chmod 600 "$dhparams"
    fi
    echo "end"
}


RunCertbot()
{
    certbot certonly \
        --non-interactive \
        --renew-by-default \
        --agree-tos \
        --email "$OWNER_EMAIL" \
        --webroot --webroot-path "$WEBROOT_PATH" \
        --domain "$OWNER_DOMAIN" \
        $([ "$DRY_RUN" ] && echo "--dry-run")
    # copy artefacts
    if [ ! "$DRY_RUN" ]; then
        path="/etc/letsencrypt/live"/"$OWNER_DOMAIN"
        cp -fv "$path"/"privkey.pem" "$KEY_PATH"
        cp -fv "$path"/"fullchain.pem" "$CERT_PATH"
    fi
}


CheckCertificateIfExists()
{
    local path="$1"
    if [ -f "$path" ]; then
        if [ $(openssl x509 -noout -subject -in "$path" | cut -d= -f3) != "$OWNER_DOMAIN" ]; then
            echo "Requested domain name does not match the domain name in provided certificate"
            exit 1
        fi
    fi
}


GetCertificateValidDays()
{
    local path="$1"
    local validDays=0
    if [ -f "$path" ]; then
        local exp=$(date -d "`openssl x509 -enddate -noout -in "$path" | cut -d= -f2`" +"%s")
        local now=$(date +"%s")
        if [ "$exp" ] && [ "$now" ]; then
            validDays=$((($exp - $now) / (60 * 60 * 24)))
        else
            validDays=
        fi
    fi
    echo "$validDays"
}


SafeGetCertificateValidDays()
{
    local validDays=$(GetCertificateValidDays "$1")
    if [ "$validDays" ]; then
        echo $(($validDays < $UPDATE_BEFORE ? 0 : $validDays - $UPDATE_BEFORE))
    else
        # default value in case of calculation issues
        echo 60
    fi
}


DisableNginxConfigs()
{
    if [ -d "$CONFD_PATH" ]; then
        mv -v "$CONFD_PATH" "$CONFD_PATH".disabled
    fi
}


EnableNginxConfigs()
{
    if [ -d "$CONFD_PATH".disabled ]; then
        mv -v "$CONFD_PATH".disabled "$CONFD_PATH"
    fi
}


UpdateLetsEncrypt()
{
    # suddon failure should not stop the update process
    set +e
    # wait for nginx
    sleep 5
    echo "Start letsencrypt updater"
    while :
    do
        echo "Trying to update letsencrypt..."
        local daysToWait=$(SafeGetCertificateValidDays "$CERT_PATH")
        sleep "$daysToWait"$([ "$DRY_RUN" ] || echo d)
        RunCertbot
        EnableNginxConfigs
        nginx -s reload
    done
}


Main()
{
    echo "Configure nginx-le"
    if [ "$DRY_RUN" ]; then
        echo "Dry run mode"
    fi
    CheckRequiredFilesAndFolders
    CheckCertificateIfExists "$CERT_PATH"
    # disable nginx configs if there is no ssl certificate
    if [ ! -f "$CERT_PATH" ]; then
        DisableNginxConfigs
    fi
    #
    MakeDhparams "$SSL_PATH"
    UpdateLetsEncrypt &
    nginx -g "daemon off;"
}


# entry point
set -ex
trap 'jobs -p | xargs -r kill' EXIT
Main "$@"
