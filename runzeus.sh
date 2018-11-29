#!/bin/bash

zeushome="/usr/local/zeus"
zcli="/usr/local/zeus/zxtm/bin/zcli --formatoutput"
zhttp="/usr/local/zeus/admin/bin/httpclient"
provisionLog="/var/log/provision.log"
configimport="/usr/local/zeus/zxtm/bin/config-import"
configsnapshot="/usr/local/zeus/zxtm/bin/config-snapshot"
watchdirectory="/usr/local/zeus/zxtm/bin/watch-directory"

plog() {
    if [ -n "$3" ]; then
        echo "$1: $2" >> $provisionLog
    else
        echo "$1: $2" | tee -a $provisionLog
    fi
}

genPasswd() {
    if [ "$ZEUS_PASS" == "RANDOM" ] || [ "$ZEUS_PASS" == "SIMPLE" ] || [ "$ZEUS_PASS" == "STRONG" ]
    then
        # Default for RANDOM/SIMPLE is alphanumeric with , . - + _
        chars=( a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5 6 7 8 9 0 \
                A B C D E F G H I J K L M N O P Q R S T U V W X Y Z , \. \- \+ \_ )
        length=9

        # Use Extra Strong Passwords (more symbols)
        if [ "$ZEUS_PASS" == "STRONG" ]
        then
            chars=( a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5 6 7 8 9 0 \
                    A B C D E F G H I J K L M N O P Q R S T U V W X Y Z , \. \< \> \~ \# \[ \] \
                    \- \= \+ \_ \* \& \^ \% \$ \; \: \( \) )
            length=16
        fi

        rnd_bytes="$(/usr/local/zeus/zxtm/bin/zxtmsecret -i <(head -c 256 /dev/urandom) -l $length -t dev-random-container-password -x)"
        pass="";
        for (( i=0; i<$length ; i++ ))
        do
            rnd_byte=${rnd_bytes:2*$i:2}
            rnd_byte=`echo $((0x$rnd_byte))`
            rnd=$(( $rnd_byte % ${#chars[@]} ))
            pass=${pass}${chars[${rnd}]}
        done

        ZEUS_PASS=$pass
        plog INFO "Generated random password for vTM: $ZEUS_PASS" quiet
    else
        plog INFO "Using environment password for vTM: $ZEUS_PASS" quiet
    fi
    echo "$ZEUS_PASS"
}

plog INFO "Container started"

# Check that the user has accepted the license
if [ "$ZEUS_EULA" != "accept" ]
then
    plog INFO "Please accept the vTM EULA by supplying the "ZEUS_EULA=accept" env. variable"
    exit 1
fi

# Configure vTM on the first run of this instance
if [ ! -f /usr/local/zeus/.docker.done ]
then

    # Do we need to check for Java Extension support?
    zeus_check_java="yes"

    plog INFO "Container first run: STARTING"
    # Install additional packages if ZEUS_PACKAGES is set. It should be set to a list of ubuntu packages
    if [[ -n "$ZEUS_PACKAGES" ]]
    then
        plog INFO "Installing packages: $ZEUS_PACKAGES"
        apt-get update
        for package in $ZEUS_PACKAGES
        do
            dpkg -l $package | egrep "^ii" > /dev/null
            ret=$?
            if [ $ret -ne 0 ]
            then
                DEBIAN_FRONTEND=noninteractive apt-get install -y \
                                --no-install-recommends $package
                if [ $? -ne 0 ]
                then
                    echo "Failed to install '$package'"
                    exit 1
                fi
            fi
        done
        rm -rf /var/lib/apt/lists/*
    fi

    ZEUS_PASS=$( genPasswd )

    if [[ "$ZEUS_LIC" =~ https?://.* ]]
    then
        ZEUS_LIC_URL=$ZEUS_LIC
        plog INFO "Downloading license key from '$ZEUS_LIC_URL'"
        $zhttp --no-verify-host -b $ZEUS_LIC > /tmp/fla.lic
        if [ $? -eq 0 ]; then
            ZEUS_LIC=/tmp/fla.lic
        else
            echo "Failed to download the license from $ZEUS_LIC"
            exit 1
        fi
    fi

    cat <<EOF >> /usr/local/zeus/zconfig.txt
accept-license=$ZEUS_EULA
admin!password=$ZEUS_PASS
Zeus::ZInstall::Common::get_password:Please choose a password for the admin server=$ZEUS_PASS
Zeus::ZInstall::Common::get_password:Re-enter=$ZEUS_PASS
zxtm!license_key=$ZEUS_LIC
EOF

    if [ -n "$ZEUS_CLUSTER_NAME" ]; then
        if [ -z "$ZEUS_CLUSTER_PORT" ]; then
            ZEUS_CLUSTER_PORT=9090
        fi
        join=n
        # Disable Java Check, we're joining a cluster
        zeus_check_java="no"
        if [ -n "$ZEUS_CLUSTER_FP" ]; then
            plog INFO "Checking cluster fingerprint: $ZEUS_CLUSTER_FP"
            $zhttp --fingerprint="${ZEUS_CLUSTER_FP}"  --verify \
                   --no-verify-host "https://${ZEUS_CLUSTER_NAME}:${ZEUS_CLUSTER_PORT}" > /dev/null
            if [ $? == 0 ]; then
                join=y
            else
                plog ERROR  "Clustering Skipped! Fingerprint does not match"
            fi
        else
            join=y
        fi
        if [ "$join" == "y" ]; then
            plog INFO "Configuring cluster join: $ZEUS_CLUSTER_NAME:$ZEUS_CLUSTER_PORT"
            while [ -n "$($zhttp --no-verify-host https://$ZEUS_CLUSTER_NAME:$ZEUS_CLUSTER_PORT > /dev/null)" ];
            do
                sleep 1
            done
            sed -i 's/zxtm!cluster=C/zxtm!cluster=S/' /usr/local/zeus/zconfig.txt
            cat <<EOF >> /usr/local/zeus/zconfig.txt
zlb!admin_hostname=$ZEUS_CLUSTER_NAME
zlb!admin_password=$ZEUS_PASS
zlb!admin_port=$ZEUS_CLUSTER_PORT
zlb!admin_username=admin
zxtm!clustertipjoin=p
zxtm!fingerprints_ok=Y
zxtm!join_new_cluster=Y
EOF
        fi
    fi

    # Setup the configuration for self registration with SD
    if [ -n "$ZEUS_REGISTER_HOST" ]; then
        register=n
        hostport=($( echo "${ZEUS_REGISTER_HOST}" | sed -re 's/:/ /' ))
        if [ -n "$ZEUS_REGISTER_FP" ]; then
            plog INFO "Checking BSD fingerprint: $ZEUS_REGISTER_FP"
            $zhttp --fingerprint="${ZEUS_REGISTER_FP}"  --verify \
                   --no-verify-host "https://${ZEUS_REGISTER_HOST}" > /dev/null
            if [ $? == 0 ]; then
                register=y
            else
                plog ERROR  "Services Director registration skipped! Fingerprint does not match"
            fi
        else
            register=y
        fi
        if [ "$register" == "y" ]; then
            plog INFO  "Configuring Services Director registration"
            cat <<EOF >> /usr/local/zeus/zconfig.txt
selfreg!register=y
selfreg!address=${hostport[0]}
selfreg!port=${hostport[1]}
selfreg!fingerprint_ok=y
selfreg!email_addr=${ZEUS_REGISTER_EMAIL}
selfreg!message=${ZEUS_REGISTER_MSG}
selfreg!policy_id=${ZEUS_REGISTER_POLICY}
selfreg!owner=${ZEUS_REGISTER_OWNER}
selfreg!owner_secret=${ZEUS_REGISTER_SECRET}
Zeus::ZInstall::Common::get_password:Enter the secret associated with the chosen Owner=${ZEUS_REGISTER_SECRET}
EOF
        fi
    fi

    if [ -n "$ZEUS_COMMUNITY_EDITION" ]
    then
        plog INFO "Accepting Community Edition"
        echo "zxtm!community_edition_accepted=y" >> /usr/local/zeus/zconfig.txt
    fi

    plog INFO "Configuring vTM"
    retries=1
    until /usr/local/zeus/zxtm/configure --nostart --noninteractive --noloop --replay-from=/usr/local/zeus/zconfig.txt
    do
        sleep 10
        plog INFO "Configuring vTM failed, retry: ${retries}"
        if [ $retries -lt 4 ]; then
            # this might be due to a missing license.
            # let's try to re-download if provided over HTTP.
            if [[ "$ZEUS_LIC" =~ https?://.* ]]
            then
                plog WARN "Retrying download license key"
                $zhttp --no-verify-host -b $ZEUS_LIC_URL > /tmp/fla.lic
                if [ $? -ne 0 ]; then
                    echo "Failed to download the license from $ZEUS_LIC"
                    exit 1
                fi
            fi
        elif [ $retries -eq 4 ]; then
            plog WARN "Disabling license and clustering requests"
            if [ -n "$ZEUS_CLUSTER_NAME" ]; then
                plog WARN "Final attempt, without cluster join"
                sed -i 's/zxtm!join_new_cluster=Y/zxtm!join_new_cluster=N/' /usr/local/zeus/zconfig.txt
                sed -i 's/zxtm!cluster=S/zxtm!cluster=C/' /usr/local/zeus/zconfig.txt
            fi
            if [ -n "$ZEUS_LIC" ]; then
                plog WARN "Final attempt, without License Key"
                sed -i 's/\/tmp\/fla.lic//' /usr/local/zeus/zconfig.txt
            fi
        elif [ $retries -gt 5 ]; then
            plog FATAL "Failed to configure vTM. Quitting!"
            exit 1
        fi
        retries=$(( $retries + 1 ))
    done

    # Clear the password
    export ZEUS_PASS=""

    if [ -n "$ZEUS_BASE_CONFIG" ]
    then

        # Disable Java Check, a base config was provided
        zeus_check_java="no"

        if [ ! -x "$configimport" ]
        then
            plog ERROR "Configuration importer not available, unset ZEUS_BASE_CONFIG"
            exit 1
        fi

        if [ ! -d "$ZEUS_BASE_CONFIG" ]
        then
            plog ERROR "ZEUS_BASE_CONFIG $ZEUS_BASE_CONFIG is not a directory"
            exit 1
        fi

        plog INFO "Importing configuration from $ZEUS_BASE_CONFIG"

        ZEUSHOME="$zeushome" "$configimport" $ZEUS_CONFIG_IMPORT_ARGS \
           --chdir "${ZEUS_BASE_CONFIG}" config
        ec=$?
        if [ $ec -ne 0 ]
        then
            plog ERROR "Failed to import configuration"
            exit 1
        else
            plog INFO "Configuration imported"
        fi
    fi

    if [ -x "$configsnapshot" ]
    then
        ZEUSHOME="$zeushome" "$configsnapshot"
    fi

    if [ -n "$ZEUS_WATCHED_CONFIG" ]
    then

        # Disable Java Check, a watched config was provided
        zeus_check_java="no"

        if [ ! -x "$watchdirectory" ]
        then
            plog ERROR "Configuration watcher not available, unset ZEUS_WATCHED_CONFIG"
            exit 1
        fi

        if [ ! -d "$ZEUS_WATCHED_CONFIG" ]
        then
            plog ERROR "ZEUS_WATCHED_CONFIG $ZEUS_WATCHED_CONFIG is not a directory"
            exit 1
        fi
    fi

    # Copy in the Docker AutoSclaing driver
	cp -p /usr/local/zeus/dockerScaler.py /usr/local/zeus/zxtm/conf/extra/

    touch /usr/local/zeus/.docker.done
    rm /usr/local/zeus/zconfig.txt
    plog INFO "Container first run COMPLETE"
    # Start Zeus
    plog INFO "Starting traffic manager"
    /usr/local/zeus/start-zeus

    # If no configuration was supplied (base-config or watcher), and we didn't join a cluster, check for java support.
    if [ "$zeus_check_java" == "yes" ]
    then
        java=$(which $(echo "GlobalSettings.getJavaCommand" | $zcli | awk '{ print $1 }' ))
        if [ -z "$java" ] 
        then
            echo "GlobalSettings.setJavaEnabled 0" | $zcli
            echo "Java not found, disabling Java Extensions"
        else 
            echo "GlobalSettings.setJavaEnabled 1" | $zcli
            echo "Java found, enabling Java Extensions"
        fi
    fi

else
    # Start Zeus
    plog INFO "Starting traffic manager"
    /usr/local/zeus/start-zeus
fi


# Start config watcher
if [ -n "$ZEUS_WATCHED_CONFIG" ]
then
    plog INFO "Watching configuration in $ZEUS_WATCHED_CONFIG"
    ZEUSHOME="$zeushome" "$watchdirectory" "$ZEUS_WATCHED_CONFIG" -- \
       "$configimport" --chdir "${ZEUS_WATCHED_CONFIG}" \
       $ZEUS_CONFIG_IMPORT_ARGS config &
fi

# Print the password and wait for SIGTERM
trap "plog INFO 'Caught SIGTERM'" SIGTERM
grep -i password /var/log/provision.log
tail -f /dev/null &
wait -n
/usr/local/zeus/stop-zeus
plog INFO "Container stopped"

