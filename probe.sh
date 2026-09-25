#!/bin/bash
# Зовнішній монітор DreamCar. Кожна перевірка з повтором; Telegram лише при збої (антиспам 60 хв) і при відновленні.
set -u
UA='Mozilla/5.0 (X11; Linux x86_64) Chrome/128 dreamcar-uptime/1.0'
fail=''
add(){ fail="$fail
X $*"; }
# code-only перевірка з очікуваним набором кодів (через кому)
chk_code(){ # url, "коди", [UA]
  local code=000
  for t in 1 2; do
    code=$(curl -sS -L --max-redirs 4 -A "${3:-$UA}" --compressed --max-time 30 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000)
    case ",$2," in *",$code,"*) return 0;; esac
    sleep 15
  done
  add "$1 -> HTTP $code (очікували $2)"
}
# перевірка з маркером у тілі
chk_body(){ # url, маркер
  local out code
  for t in 1 2; do
    out=$(curl -sS -L --max-redirs 4 -A "$UA" --compressed --max-time 30 -w '\n__%{http_code}' "$1" 2>/dev/null || true)
    code=${out##*__}
    if [ "$code" = 200 ] && grep -qiF -- "$2" <<<"$out"; then return 0; fi
    sleep 15
  done
  add "$1 -> HTTP $code або немає «$2»"
}

# 1) Публічна воронка (найкритичніше — активний цикл)
# apex має або редіректити (301/302) або віддавати 200; 522/5xx = origin down
chk_code https://dreamcar.ua/            '200,301,302'
chk_code https://www.dreamcar.ua/        '200,301,302'
chk_body https://audiq7.dreamcar.ua/     'dreamcar'
chk_code https://ai.dreamcar.ua/         '200,301,302'
# 2) Внутрішні інструменти (GitHub Pages)
chk_code https://team.dreamcar.ua/       '200,301,302'
chk_code https://dashboard.dreamcar.ua/  '200,301,302'
chk_body https://brand.dreamcar.ua/      'dreamcar'
# global-header — спільна залежність усіх внутрішніх сторінок
chk_code https://brand.dreamcar.ua/assets/global-header.js '200'

# 3) Supabase health: REST-корінь має відповідати (200/401/404), НЕ 5xx; 5xx = БД/Auth впали
sb=$(curl -sS -o /dev/null -A "$UA" --max-time 20 -w '%{http_code}' https://wotghlaehnvxyeacznvv.supabase.co/rest/v1/ || echo 000)
case "$sb" in 5*|000) add "Supabase REST -> HTTP $sb (БД/Auth під загрозою)";; esac
au=$(curl -sS -o /dev/null -A "$UA" --max-time 20 -w '%{http_code}' https://wotghlaehnvxyeacznvv.supabase.co/auth/v1/health || echo 000)
case "$au" in 5*|000) add "Supabase Auth health -> HTTP $au";; esac

# 4) Сертифікати
for host in dreamcar.ua audiq7.dreamcar.ua; do
  exp=$(echo | openssl s_client -servername "$host" -connect "$host":443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$exp" ]; then
    days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
    [ "$days" -lt 14 ] && add "Сертифікат $host спливає через ${days} дн."
  else
    add "Не вдалось прочитати сертифікат $host"
  fi
done

# ---- повідомлення (антиспам через state/ з кешу Actions) ----
mkdir -p state; now=$(date +%s)
tg(){ [ -n "${TG_TOKEN:-}" ] && curl -sS -o /dev/null --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=$1" \
      --data-urlencode "disable_web_page_preview=true" "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"; }
if [ -n "$fail" ]; then
  h=$(printf '%s' "$fail" | sha1sum | cut -c1-12); read -r ph pt < state/last 2>/dev/null || { ph=''; pt=0; }
  if [ "$h" != "$ph" ] || [ $((now - pt)) -ge 3600 ]; then tg "[dreamcar uptime]$fail"; echo "$h $now" > state/last; fi
  printf 'FAILED:%s\n' "$fail"; exit 1
fi
if [ -s state/last ]; then tg "[dreamcar uptime] усі зовнішні перевірки знову зелені"; rm -f state/last; fi
echo "all green"
