#!/bin/bash

zcli="/usr/local/zeus/zxtm/bin/zcli --formatoutput"
zhttp="/usr/local/zeus/admin/bin/httpclient"
provisionLog="/var/log/provision.log"

plog() {
   echo "$1: $2" >> $provisionLog
}

genPasswd() {
   if [ "$ZEUS_PASS" == "RANDOM" ] || [ "$ZEUS_PASS" == "SIMPLE" ] || [ "$ZEUS_PASS" == "STRONG" ]
   then

		# Default for RANDOM/SIMPLE is alphanumeric with , . - + _ 
		chars=( a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5 6 7 8 9 0 \
			     A B C D E F G H I J K L M N O P Q R S T U V W X Y Z , \. \- \+ \_ )

		# Use Extra Strong Passwords (more symbols)
		if [ "$ZEUS_PASS" == "STRONG" ]
		then
      	chars=( a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5 6 7 8 9 0 \
                 A B C D E F G H I J K L M N O P Q R S T U V W X Y Z , \. \< \> \~ \# \[ \] \
                 \- \= \+ \_ \* \& \^ \% \$ \; \: \( \) )
		fi

      length=$(( 9 + $(( $RANDOM % 3 )) ))
      pass="";

      for (( i=0; i<$length ; i++ ))
      do
         rnd=$(( $RANDOM % ${#chars[@]} ))
         pass=${pass}${chars[${rnd}]}
      done
      ZEUS_PASS=$pass
      plog INFO "Generated Random Password for vTM: $ZEUS_PASS"
   else
      plog INFO "Using Environment Password for vTM: $ZEUS_PASS"
   fi
   echo "$ZEUS_PASS"
}

plog INFO "Container Started"

# update the hostname if we were given a ZEUS_DOM
if [[ -n "$ZEUS_DOM" ]]
then
	echo "Updating FQDN using $ZEUS_DOM"
	hostname=$( hostname -s )
	fqdn=${hostname}.${ZEUS_DOM}
	hostname $fqdn
	echo $fqdn > /etc/hostname

	# Prior to 1.20 this will fail and an external script will need to change this or set up DNS for us.
	echo "Attempting to modify /etc/hosts"
	sed -i -e "s/${hostname}/${hostname} ${fqdn}/" /etc/hosts 
	[ $? -eq 0 ] && echo "/etc/hosts update worked" || echo "/etc/hosts update failed"
fi

# Configure vTM on the first run of this instance
if [ ! -f /usr/local/zeus/docker.done ] 
then

    plog INFO "Container First Run: STARTING"
	# Install additional packages if ZEUS_PACKAGES is set. It should be set to a list of ubuntu packages
	if [[ -n "$ZEUS_PACKAGES" ]]
	then
        plog INFO "Installing Packages: $ZEUS_PACKAGES"
		apt-get update
		for package in $ZEUS_PACKAGES
		do
			dpkg -l $package | egrep "^ii" > /dev/null
			ret=$?
			if [ $ret -ne 0 ]
			then
				DEBIAN_FRONTEND=noninteractive apt-get install -y $package
			fi
		done
		apt-get clean
	fi

	ZEUS_PASS=$( genPasswd )

	if [[ "$ZEUS_LIC" =~ http.* ]]
	then
		ZEUS_LIC_URL=$ZEUS_LIC
		plog INFO "Downloading license key"
		curl --silent $ZEUS_LIC -o /tmp/fla.lic
		ZEUS_LIC=/tmp/fla.lic
	fi

	cat <<-EOF >> /usr/local/zeus/zconfig.txt
		accept-license=$ZEUS_EULA
		admin!password=$ZEUS_PASS
		Zeus::ZInstall::Common::get_password:Please choose a password for the admin server=$ZEUS_PASS
		Zeus::ZInstall::Common::get_password:Re-enter=$ZEUS_PASS
		zxtm!license_key=$ZEUS_LIC
	EOF

	if [ -n "$ZEUS_CLUSTER_NAME" ]; then
		plog INFO "Joining Cluster: $ZEUS_CLUSTER_NAME"
		while [ -n "$(curl -k -s -S -o/dev/null https://$ZEUS_CLUSTER_NAME:9090)" ];
		do
			sleep 1
		done
		sed -i 's/zxtm!cluster=C/zxtm!cluster=S/' /usr/local/zeus/zconfig.txt
		cat <<-EOF >> /usr/local/zeus/zconfig.txt
			zlb!admin_hostname=$ZEUS_CLUSTER_NAME
			zlb!admin_password=$ZEUS_PASS
			zlb!admin_port=9090
			zlb!admin_username=admin
			zxtm!clustertipjoin=p
			zxtm!fingerprints_ok=Y
		EOF
	fi

    # Setup the configuration for self registration with SD
    if [ -n "$ZEUS_REGISTER_HOST" ] && [ -n "$ZEUS_REGISTER_FP" ]; then
        hostport=($( echo "${ZEUS_REGISTER_HOST}" | sed -re 's/:/ /' ))
        $zhttp --fingerprint="${ZEUS_REGISTER_FP}"  --verify \
               --no-verify-host "https://${ZEUS_REGISTER_HOST}" > /dev/null
        if [ $? == 0 ]; then
   	        plog INFO  "Service Director Registration OK! Cert Check Passed"
			cat <<-EOF >> /usr/local/zeus/zconfig.txt
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
        else
   	        plog ERROR  "Service Director Registration Skipped! Fingerprint does not match"
        fi
    fi

    plog INFO "Configuring vTM"
	until /usr/local/zeus/zxtm/configure --noninteractive --noloop --replay-from=/usr/local/zeus/zconfig.txt
	do
		sleep 1
		# this might be due to a missing license.
		# let's try to re-download if provided over HTTP.
		if [[ "$ZEUS_LIC_URL" =~ http.* ]]
		then
			plog WARN "Retrying Download license key"
			curl --silent $ZEUS_LIC_URL -o /tmp/fla.lic
		fi
	done

	touch /usr/local/zeus/docker.done
	rm /usr/local/zeus/zconfig.txt

	# Clear the password
	export ZEUS_PASS=""

	# Ensure REST is enabled
	plog INFO "Enabling REST API"
	echo "GlobalSettings.setRESTEnabled 1" | $zcli

	# Disable Java Extensions if we don't have the java binary
	echo -en "Checking for JAVA Extension Support: "
	which $(echo "GlobalSettings.getJavaCommand" | $zcli | awk '{ print $1 }' ) || \
			( echo "java not found" && echo "GlobalSettings.setJavaEnabled 0" | $zcli )

	if [ -n "$ZEUS_DEVMODE" ]
	then
		plog INFO "Accepting developer mode"
		echo -e "developer_mode_accepted\tyes" >> /usr/local/zeus/zxtm/global.cfg
	fi

    plog INFO "Container First Run COMPLETE"

else
	# Start Zeus
	/usr/local/zeus/start-zeus 
fi


# Print the password and wait for SIGTERM
trap "echo 'Caught SIGTERM'" SIGTERM
grep -i password /var/log/provision.log
tail -f /dev/null &
wait $!
/usr/local/zeus/stop-zeus
echo "Container Stopped"

