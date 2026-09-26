#!/bin/bash
# Зовнішній монітор DreamCar з GitHub Actions.
# ВАЖЛИВО: раннери Actions мають датацентрові IP, і Cloudflare віддає їм БОТ-ЧЕЛЕНДЖ (HTTP 403) на *.dreamcar.ua.
# 403 тут = "CF живий і фільтрує ботів", а НЕ реальний збій. Тому алертимо лише на 5xx/000 (origin/edge down —
# саме той клас, що був у apex 522) і на прострочені сертифікати. 200/301/302/401/403/404 = доступно.
set -u
UA='Mozilla/5.0 (X11; Linux x86_64) Chrome/128 dreamcar-uptime/1.0'
fail=''
add(){ fail="$fail
X $*"; }

# origin/edge health: скарга лише якщо 5xx або нема відповіді (000). Реагує на 52x (Cloudflare origin down).
chk_up(){ # url
  local code=000
  for t in 1 2; do
    code=$(curl -sS -L --max-redirs 4 -A "$UA" --compressed --max-time 30 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000)
    case "$code" in 000|5??) sleep 15;; *) return 0;; esac
  done
  add "$1 -> HTTP $code (origin/edge down)"
}

# 1) Публічна воронка (активний цикл)
chk_up https://dreamcar.ua/
chk_up https://www.dreamcar.ua/
chk_up https://audiq7.dreamcar.ua/
chk_up https://ai.dreamcar.ua/
# 2) Внутрішні інструменти (GitHub Pages)
chk_up https://team.dreamcar.ua/
chk_up https://dashboard.dreamcar.ua/
chk_up https://brand.dreamcar.ua/
chk_up https://brand.dreamcar.ua/assets/global-header.js

# 3) Supabase health (не за CF-челенджем): 5xx/000 = БД/Auth впали
sb=$(curl -sS -o /dev/null -A "$UA" --max-time 20 -w '%{http_code}' https://wotghlaehnvxyeacznvv.supabase.co/rest/v1/ || echo 000)
case "$sb" in 000|5??) add "Supabase REST -> HTTP $sb (БД/Auth під загрозою)";; esac
au=$(curl -sS -o /dev/null -A "$UA" --max-time 20 -w '%{http_code}' https://wotghlaehnvxyeacznvv.supabase.co/auth/v1/health || echo 000)
case "$au" in 000|5??) add "Supabase Auth health -> HTTP $au";; esac

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
