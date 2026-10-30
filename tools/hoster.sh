#!/usr/bin/env bash
set -e
if [ -n "$HOSTER_SSH_KEY" ]; then
  mkdir -p ~/.ssh
  printf '%s\n' "$HOSTER_SSH_KEY" > ~/.ssh/hoster && chmod 600 ~/.ssh/hoster
  printf '%s\n' "$HOSTER_KNOWN_HOSTS" >> ~/.ssh/known_hosts
  mkdir -p tmp
  SSH="ssh -i $HOME/.ssh/hoster -o BatchMode=yes -o ConnectTimeout=30"
  if rsync -rlz --checksum --delete --exclude=/.well-known/ --exclude=/_test/ --exclude=/pb/ --out-format='%n' \
       -e "$SSH" _site/ h220178@vh167.hoster.by:www/monitorg.by/ > tmp/hoster_changed.txt; then
    echo "hoster.by: выложено, изменено файлов: $(wc -l < tmp/hoster_changed.txt)"
    ruby app/indexnow.rb tmp/indexnow.txt || true
  else
    echo "::warning::выкладка на hoster.by не удалась"
  fi
  if [ -d tmp/pb ] && ls tmp/pb/*.webp >/dev/null 2>&1; then
    rsync -rlz --ignore-existing --include='*.webp' --exclude='*' -e "$SSH" tmp/pb/ h220178@vh167.hoster.by:www/monitorg.by/pb/ \
      && echo "hoster.by: большие фото — $(ls tmp/pb/*.webp | wc -l) новых или повторных" || echo "::warning::большие фото не выложены"
  fi
  ruby -rjson -e 'l = JSON.parse(File.read("data/lots.json")); l = l.values if l.is_a?(Hash); puts l.map { |x| x["pb"] && "#{x["pb"]}.webp" }.compact.uniq' > tmp/pb_keep.txt 2>/dev/null || true
  if [ "$(wc -l < tmp/pb_keep.txt)" -ge 100 ]; then
    rsync -z -e "$SSH" tmp/pb_keep.txt h220178@vh167.hoster.by:www/pb_keep.txt \
      && $SSH h220178@vh167.hoster.by 'cd www/monitorg.by/pb 2>/dev/null && find . -maxdepth 1 -name "*.webp" -mtime +7 | sed "s#^\./##" | grep -vxFf ../../pb_keep.txt | xargs -r rm -f' || true
  fi
  used=$($SSH h220178@vh167.hoster.by 'du -sm ~ 2>/dev/null | cut -f1' 2>/dev/null || echo 0)
  echo "hoster.by: занято ${used} МБ из 3000"
  if [ "${used:-0}" -ge 2400 ] && [ "$(TZ=Europe/Minsk date +%H)" = "09" ]; then
    ruby app/alert.rb --event "на хостинге занято ${used} МБ из 3000 (80%+) — пора расширять место" || true
  fi
  rm -f ~/.ssh/hoster
else
  echo "HOSTER_SSH_KEY не задан — на hoster.by не выкладываю"
fi
rm -rf _pages
rsync -a --exclude=/lot/ --exclude=/transport/ --exclude=/nedvizhimost/ --exclude=/oborudovanie/ --exclude=/arenda/ \
      --exclude=/ploshchadki/ --exclude='/sitemap*' --exclude=/.htaccess _site/ _pages/
