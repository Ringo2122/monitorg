#!/usr/bin/env bash
# Выкладка сайта на hoster.by (21.10.2026): rsync по SSH-ключу из секретов GitHub (HOSTER_SSH_KEY, HOSTER_KNOWN_HOSTS).
# Отправляются только изменившиеся файлы (сравнение по содержимому). Сбой выкладки сюда не роняет прогон —
# пока домен на GitHub Pages, главная копия там. Потом — копия для Pages без SEO-страниц: у Pages лимит 1 ГБ.
set -e
if [ -n "$HOSTER_SSH_KEY" ]; then
  mkdir -p ~/.ssh
  printf '%s\n' "$HOSTER_SSH_KEY" > ~/.ssh/hoster && chmod 600 ~/.ssh/hoster
  printf '%s\n' "$HOSTER_KNOWN_HOSTS" >> ~/.ssh/known_hosts
  if rsync -rlz --checksum --delete --exclude=/.well-known/ \
       -e "ssh -i $HOME/.ssh/hoster -o BatchMode=yes -o ConnectTimeout=30" \
       _site/ h220178@vh167.hoster.by:www/monitorg.by/; then
    echo "hoster.by: выложено"
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
