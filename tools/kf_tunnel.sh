#!/usr/bin/env bash
if [ -z "$HOSTER_SSH_KEY" ]; then echo "HOSTER_SSH_KEY не задан — konfiskat напрямую"; exit 0; fi
mkdir -p ~/.ssh
printf '%s\n' "$HOSTER_SSH_KEY" > ~/.ssh/kf && chmod 600 ~/.ssh/kf
printf '%s\n' "$HOSTER_KNOWN_HOSTS" >> ~/.ssh/known_hosts
K="$(cd "$(dirname "$0")" && pwd)/kf_curl.sh"
ssh -i ~/.ssh/kf -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
    -o ControlMaster=yes -o ControlPath="$HOME/.ssh/kf.ctl" -o ControlPersist=yes -f -N h220178@vh167.hoster.by \
  || echo "::warning::общее соединение с hoster.by не открылось — каждый запрос подключится отдельно"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
page=$(bash "$K" -sS -m 40 -A "$UA" https://konfiskat.by/avtotransport/auktsiony/ 2>&1)
if printf '%s' "$page" | grep -q 'product-card\|Ничего не найдено'; then
  echo "KF_CURL=$K" >> "$GITHUB_ENV"
  echo "konfiskat: через hoster.by — отвечает"
else
  echo "::warning::konfiskat через hoster.by не ответил: $(printf '%s' "$page" | head -c 300)"
fi
