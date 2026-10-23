#!/usr/bin/env bash
if [ -z "$HOSTER_SSH_KEY" ]; then echo "HOSTER_SSH_KEY не задан — konfiskat напрямую"; exit 0; fi
mkdir -p ~/.ssh
printf '%s\n' "$HOSTER_SSH_KEY" > ~/.ssh/kf && chmod 600 ~/.ssh/kf
printf '%s\n' "$HOSTER_KNOWN_HOSTS" >> ~/.ssh/known_hosts
H=h220178@vh167.hoster.by
if ssh -i ~/.ssh/kf -o BatchMode=yes -o ConnectTimeout=30 -o ExitOnForwardFailure=yes \
       -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -f -N -D 127.0.0.1:1080 "$H"; then
  code=$(curl -sS -m 40 --socks5-hostname 127.0.0.1:1080 -o /dev/null -w '%{http_code}' https://konfiskat.by/ 2>&1)
  if [ "$code" = 200 ]; then
    echo "KF_PROXY=127.0.0.1:1080" >> "$GITHUB_ENV"
    echo "konfiskat: через hoster.by — отвечает"
  else
    echo "::warning::konfiskat через туннель hoster.by не ответил ($code)"
    ssh -i ~/.ssh/kf -o BatchMode=yes -o ConnectTimeout=30 "$H" \
      "curl -sS -m 30 -o /dev/null -w 'с сервера: %{http_code}' https://konfiskat.by/" 2>&1 || true
    echo
  fi
else
  echo "::warning::туннель на hoster.by не открылся"
fi
rm -f ~/.ssh/kf
