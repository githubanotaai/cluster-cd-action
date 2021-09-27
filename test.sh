#!/usr/bin/env bash

docker build -t cd .

docker run -it -v /var/run/docker.sock:/var/run/docker.sock --rm cd
