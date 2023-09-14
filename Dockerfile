FROM igrowdigital/actor:latest

WORKDIR /action

COPY entrypoint.sh .
RUN chmod +x /action/entrypoint.sh

ENTRYPOINT [ "/action/entrypoint.sh" ]
