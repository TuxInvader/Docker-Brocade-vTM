FROM ubuntu:22.04
COPY zinstall.txt /tmp/
ENV ZEUSFILE=ZeusTM_213_Linux-x86_64.tgz
COPY installer/ /tmp/
RUN cd /tmp/ \
&&  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils curl iproute2 iptables libxtables12 python3-requests \
&&  if [ ! -f /tmp/$ZEUSFILE ]; then \
    echo "Downloading VTM Installer... Please wait..." ; \
    curl -sSL http://www.badpenguin.co.uk/vadc/$ZEUSFILE > $ZEUSFILE ; \
    fi \
&&  tar -zxvf $ZEUSFILE \
&&  /tmp/Zeus*/zinstall --replay-from=/tmp/zinstall.txt --noninteractive \
&&  rm -rf /tmp/* \
&&  apt-get clean
COPY dockerScaler.py zconfig.txt runzeus.sh /usr/local/zeus/
# ZEUS_EULA must be set to "accept" otherwise the container will do nothing
ENV ZEUS_EULA=
# ZEUS_LIC can be used to pass a URL from which the container will download a license file
ENV ZEUS_LIC=
# ZEUS_PASS can be used to set a password. By default a password will be generated for you
# ZEUS_PASS=[RANDOM|SIMPLE]: generate a random pass, ZEUS_PASS=STRONG to employ more symbols.
# Or ZEUS_PASS=<your password>
ENV ZEUS_PASS=RANDOM
# ZEUS_DOM can be used to set a domain and ensure the host has a FQDN.
ENV ZEUS_DOM=
# ZEUS_PACKAGES can be used to install additional packages on first run. 
# If you need Java Extensions.... Eg ZEUS_PACKAGES="openjdk-7-jre-headless"
ENV ZEUS_PACKAGES=
# ZEUS_COMMUNITY_EDITION can be used accept the Community Edition license, and avoid being asked on login
ENV ZEUS_COMMUNITY_EDITION=
# ZEUS_CLUSTER_NAME is used to set the DNS name of an existing member of an existing cluster
# we wish to get this new vtm integrated into.
ENV ZEUS_CLUSTER_NAME=
# ZEUS Service Director Registratrions
ENV ZEUS_REGISTER_HOST=
ENV ZEUS_REGISTER_FP=
ENV ZEUS_REGISTER_POLICY=
ENV ZEUS_REGISTER_OWNER=
ENV ZEUS_REGISTER_SECRET=
CMD [ "/usr/local/zeus/runzeus.sh" ]
EXPOSE 9070 9080 9090 9090/udp 80 443
