FROM ubuntu

RUN mkdir -p /home/manifest/.../
WORKDIR /home/manifest/.../

RUN apt-get update && apt-get install -y \
    git \
    vim \
    curl \
    tree \
    sudo \
    python3 \
    python3-pip

RUN pip3 install \
    ruamel.yaml

# add non-priviledged user
RUN groupadd --gid 1000 manifest && \
    adduser --uid 1000 --disabled-password --gecos '' --ingroup manifest manifest

COPY . /home/manifest/.../

# change user
RUN chown manifest:manifest -R /home/manifest
USER manifest
