# ═══════════════════════════════════════════════════════════════
#  Pod — prostředí, ve kterém běží agent
#
#  Nemá git credentials, nemá přístup k Docker socketu, neběží pod
#  rootem a ven se dostane jen přes egress-proxy.
# ═══════════════════════════════════════════════════════════════
FROM node:22-slim

# git je tu kvůli lokálním commitům. Síťové operace (fetch, push) dělá
# hostitel — pod nikdy nevidí přihlašovací údaje k repozitáři.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates python3 python3-venv jq less \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @earendil-works/pi-coding-agent \
    && npm cache clean --force

# Nezakládáme nového uživatele — obraz node už má uid/gid 1000 (node).
# Launcher pod tímhle uid pouští kontejner, aby soubory ve /workspace
# patřily člověku na hostiteli, ne rootovi.
RUN mkdir -p /run/agenticdev /ctx /workspace \
    && chown -R node:node /run/agenticdev

COPY harness/harness.py harness/director.py /opt/agenticdev/
RUN chmod 0555 /opt/agenticdev/harness.py /opt/agenticdev/director.py

USER node
WORKDIR /workspace

ENV AGENTICDEV_IN_POD=1 \
    GIT_TERMINAL_PROMPT=0 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

ENTRYPOINT ["python3", "/opt/agenticdev/harness.py"]
