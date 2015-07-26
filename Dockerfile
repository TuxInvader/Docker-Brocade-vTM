FROM ubuntu-debootstrap:14.04.2
ADD https://support.riverbed.com/bin/support/download?sid=6mv0npda0dlj836kdbo451gtd /tmp/
COPY zinstall.txt /tmp/
RUN tar -C /tmp -zxvf /tmp/download*
RUN /tmp/Zeus*/zinstall --replay-from=/tmp/zinstall.txt --noninteractive
RUN rm -rf /tmp/*
COPY zconfig.txt /usr/local/zeus/
COPY runzeus.sh /usr/local/zeus/
ENV ZEUS_EULA=
ENV ZEUS_LIC=
ENV ZEUS_PASS=RANDOM
ENV ZEUS_DOM=
CMD [ "/usr/local/zeus/runzeus.sh" ]
EXPOSE 9070 9080 9090 80 443
