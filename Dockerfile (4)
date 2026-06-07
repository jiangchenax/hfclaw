FROM node:22-slim

ENV HOME=/home/node
ENV APP_HOME=/home/node/app
ENV PATH=$PATH:$APP_HOME/node_modules/.bin
WORKDIR $APP_HOME

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates python3 python3-pip curl git && \
    pip3 install --no-cache-dir huggingface_hub boto3 --break-system-packages && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/node/app/configs && \
    mkdir -p /home/node/.openclaw && \
    chown -R node:node /home/node

USER node
RUN npm install openclaw@latest @larksuiteoapi/node-sdk @tencent-weixin/openclaw-weixin --no-audit --no-fund && \
    npm install grammy @slack/web-api @buape/carbon --no-audit --no-fund

COPY --chown=node:node configs/ ./configs/
COPY --chown=node:node start.sh ./start.sh
COPY --chown=node:node sync.py ./sync.py
COPY --chown=node:node backup_controller.py ./backup_controller.py

RUN chmod +x ./start.sh

EXPOSE 7860
CMD ["./start.sh"]