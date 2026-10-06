###########################################################
# Dockerfile that builds a Project Zomboid Gameserver
###########################################################
# Built on the image's own base for its C library; the compiler stays in this stage.
FROM cm2network/steamcmd:root AS shim
RUN apt-get update \
  && apt-get install -y --no-install-recommends --no-install-suggests gcc libc6-dev
COPY shim/no_file_watcher.c /src/
RUN gcc -O2 -Wall -Wextra -Werror -shared -fPIC -o /src/no_file_watcher.so /src/no_file_watcher.c

FROM cm2network/steamcmd:root

ENV STEAMAPPID=380870
ENV STEAMAPP=pz
ENV STEAMAPPDIR="${HOMEDIR}/${STEAMAPP}-dedicated"
# Fix for a new installation problem in the Steamcmd client
ENV HOME="${HOMEDIR}"

# Space-separated locales to install besides en_US.UTF-8, for example "es_ES.UTF-8 de_DE.UTF-8".
ARG EXTRA_LOCALES=""

RUN apt-get update \
  && apt-get install -y --no-install-recommends --no-install-suggests \
  jq \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN for locale in en_US.UTF-8 ${EXTRA_LOCALES}; do \
       sed -i "s/^# *\(${locale}\)/\1/" /etc/locale.gen; \
     done \
  && locale-gen

# Created here so new named volumes start out owned by the steam user.
RUN mkdir -p "${STEAMAPPDIR}" "${HOMEDIR}/Zomboid" \
  && chown -R "${USER}:${USER}" "${HOMEDIR}"

COPY --chmod=755 scripts /server/scripts
COPY --from=shim /src/no_file_watcher.so /usr/local/lib/no_file_watcher.so
# image-env lists the variables the image sets itself, so startup can warn about unknown ones.
RUN ln -s /server/scripts/list_env.sh /usr/local/bin/list-env \
  && ln -s /server/scripts/list_mods.sh /usr/local/bin/list-mods \
  && ln -s /server/scripts/console.sh /usr/local/bin/console \
  && env | cut -d= -f1 | sort > /server/scripts/image-env

USER ${USER}
WORKDIR ${HOMEDIR}

EXPOSE 16261-16262/udp \
  27015/tcp

# The first start downloads the game, and large modded servers take long to start; the check only
# counts once the server is up.
HEALTHCHECK --start-period=60m --interval=30s --timeout=10s --retries=3 \
  CMD ["/server/scripts/healthcheck.sh"]

ENTRYPOINT ["/server/scripts/entry.sh"]
