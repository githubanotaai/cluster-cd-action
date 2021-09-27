FROM alpine:3.14

WORKDIR /action

ADD https://github.com/mikefarah/yq/releases/download/3.3.2/yq_linux_amd64 /usr/local/bin/yq
RUN chmod +x /usr/local/bin/yq

ADD https://download.docker.com/linux/static/stable/x86_64/docker-20.10.8.tgz /opt/docker.tgz
RUN cd /opt && tar xfzv docker.tgz && install docker/docker /usr/local/bin/docker

RUN apk add bash git

COPY . .
RUN chmod +x /action/entrypoint.sh

ENTRYPOINT [ "/action/entrypoint.sh" ]
