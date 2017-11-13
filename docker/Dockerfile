FROM centos:latest

ENV             MCROUTER_DIR            /usr/local/mcrouter
ENV             MCROUTER_REPO           https://github.com/facebook/mcrouter.git

RUN yum -y update && yum -y install git memcached sudo && \
                mkdir -p $MCROUTER_DIR/repo && \
                cd $MCROUTER_DIR/repo && git clone $MCROUTER_REPO && \
                cd $MCROUTER_DIR/repo/mcrouter/mcrouter/scripts && \
                ./install_centos_7.2.sh $MCROUTER_DIR && \
                rm -rf $MCROUTER_DIR/repo && rm -rf $MCROUTER_DIR/pkgs && \
                ln -s $MCROUTER_DIR/install/bin/mcrouter /usr/local/bin/mcrouter && \
                yum -y clean all && yum -y erase "*-devel" && yum -y erase git

COPY docker-entrypoint.sh /

RUN mkdir -p /var/spool/mcrouter /var/mcrouter  && chown -R nobody:nobody /var/spool/mcrouter /var/mcrouter
USER nobody
ENTRYPOINT  ["/docker-entrypoint.sh"] 

CMD memcached

EXPOSE 11211
EXPOSE 11212
