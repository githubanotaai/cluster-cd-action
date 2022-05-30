FROM alpine:3.14

WORKDIR /action

COPY resources/yq /usr/local/bin/yq
RUN chmod +x /usr/local/bin/yq

COPY resources/docker.tgz /opt/docker.tgz
RUN cd /opt && tar xfzv docker.tgz && install docker/docker /usr/local/bin/docker

RUN apk add bash git

COPY entrypoint.sh .
RUN chmod +x /action/entrypoint.sh

ENTRYPOINT [ "/action/entrypoint.sh" ]
