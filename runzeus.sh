#!/bin/bash

zcli="/usr/local/zeus/zxtm/bin/zcli --formatoutput"
provisionLog="/var/log/provision.log"

plog() {
   echo "$1: $2" >> $provisionLog
}

genPasswd() {
   if [ "$ZEUS_PASS" == "RANDOM" ]
   then
      chars=( a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5 6 7 8 9 0 \
              A B C D E F G H I J K L M N O P Q R S T U V W X Y Z , \. \< \> \~ \# \[ \] \
              \- \= \+ \_ \) \( \* \& \^ \% \$ \" \! \' \; \: )
      length=$(( 9 + $(( $RANDOM % 3 )) ))
      pass="";

      for (( i=0; i<$length ; i++ ))
      do
         rnd=$(( $RANDOM % ${#chars[@]} ))
         pass=${pass}${chars[${rnd}]}
      done
      ZEUS_PASS=$pass
      plog INFO "Generated Random Password for Stingray: $ZEUS_PASS"
	else
   	plog INFO "Using Environment Password for Stingray: $ZEUS_PASS"
   fi
   echo "$ZEUS_PASS"
}

echo "Container Started"

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

	ZEUS_PASS=$( genPasswd )

	if [[ "$ZEUS_LIC" =~ http.* ]]
	then
		/usr/local/zeus/admin/bin/httpclient $ZEUS_LIC > /tmp/fla.lic
		ZEUS_LIC=/tmp/fla.lic
	fi

	cat <<-EOF >> /usr/local/zeus/zconfig.txt
		accept-license=$ZEUS_EULA
		admin!password=$ZEUS_PASS
		Zeus::ZInstall::Common::get_password:Please choose a password for the admin server=$ZEUS_PASS
		Zeus::ZInstall::Common::get_password:Re-enter=$ZEUS_PASS
		zxtm!license_key=$ZEUS_LIC
	EOF
	/usr/local/zeus/zxtm/configure --replay-from=/usr/local/zeus/zconfig.txt --nostart
	touch /usr/local/zeus/docker.done

	# Clear the password
	export ZEUS_PASS=""
fi

# Start Zeus
/usr/local/zeus/start-zeus 

# Ensure REST is enabled
echo "GlobalSettings.setRESTEnabled 1" | $zcli

# Print the password and wait for SIGTERM
trap "echo 'Caught SIGTERM'" SIGTERM
grep -i password /var/log/provision.log
tail -f /dev/null &
wait $!
/usr/local/zeus/stop-zeus
echo "Container Stopped"

