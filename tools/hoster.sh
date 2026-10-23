#!/usr/bin/env bash
set -e
if [ -n "$HOSTER_SSH_KEY" ]; then
  mkdir -p ~/.ssh
  printf '%s\n' "$HOSTER_SSH_KEY" > ~/.ssh/hoster && chmod 600 ~/.ssh/hoster
  printf '%s\n' "$HOSTER_KNOWN_HOSTS" >> ~/.ssh/known_hosts
  mkdir -p tmp
  if rsync -rlz --checksum --delete --exclude=/.well-known/ --exclude=/_test/ --out-format='%n' \
       -e "ssh -i $HOME/.ssh/hoster -o BatchMode=yes -o ConnectTimeout=30" \
       _site/ h220178@vh167.hoster.by:www/monitorg.by/ > tmp/hoster_changed.txt; then
    echo "hoster.by: выложено, изменено файлов: $(wc -l < tmp/hoster_changed.txt)"
    ruby app/indexnow.rb tmp/hoster_changed.txt || true
  else
    echo "::warning::выкладка на hoster.by не удалась"
  fi
  rm -f ~/.ssh/hoster
else
  echo "HOSTER_SSH_KEY не задан — на hoster.by не выкладываю"
fi
rm -rf _pages
rsync -a --exclude=/lot/ --exclude=/transport/ --exclude=/nedvizhimost/ --exclude=/oborudovanie/ --exclude=/arenda/ \
      --exclude=/ploshchadki/ --exclude='/sitemap*' --exclude=/.htaccess _site/ _pages/
