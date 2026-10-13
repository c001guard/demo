#!/usr/bin/env bash
# check_ticket.sh — автоматическая проверка практического билета экзамена.
# Запуск на ВМ студента, от root:
#   sudo ./check_ticket.sh <билет 1-6> <вариант 1|2> [--no-flap]
#
#   --no-flap                не останавливать и не запускать службу (пункт «стоп/старт» не засчитывается)
#
# Баллы: служба 5 пунктов x 10 = 50, мониторинг 3 пункта x 10 = 30.
set -u

usage() {
  echo "Использование: sudo $0 <билет 1-6> <вариант 1|2> [--no-flap]"
  exit 2
}

T="${1:-}"
V="${2:-}"
[ "$(id -u)" -eq 0 ] || usage
[[ "$T" =~ ^[1-6]$ && "$V" =~ ^[12]$ ]] || usage
shift 2

FLAP=1
for a in "$@"; do
  case "$a" in
    --no-flap) FLAP=0 ;;
    *) usage ;;
  esac
done

PW='Exam2024!'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "exam check" > "$TMP/f.txt"

SVC=0
MONS=0

# chk <переменная-счётчик> "описание" команда [аргументы...]
chk() {
  local var="$1" desc="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    echo "  PASS  +10  $desc"
    eval "$var=\$(( $var + 10 ))"
  else
    echo "  FAIL    0  $desc"
  fi
}

listen() { ss -ltn 2>/dev/null | grep -qE ":$1[[:space:]]"; }

# ---------- Параметры мониторинга по билету ----------
# Внимание: в regex для PromQL нет обратных слэшей (в двойных кавычках PromQL они ломают разбор).
case "$T" in
  1) REGEX='(named|bind9).service'; CTL=bind9 ;;
  2)
    if systemctl is-active --quiet apache2; then
      REGEX='apache2.service'; CTL=apache2
    else
      REGEX='nginx.service'; CTL=nginx
    fi
    ;;
  3) REGEX='nginx.service'; CTL=nginx ;;
  4)
    if [ "$V" = 1 ]; then
      REGEX='smbd.service'; CTL=smbd
    else
      REGEX='(nfs-server|nfs-kernel-server).service'; CTL=nfs-kernel-server
    fi
    ;;
  5) REGEX='proftpd.service'; CTL=proftpd ;;
  6) REGEX='postfix(@-)?.service'; CTL=postfix ;;
esac

echo "=============================================="
echo " Билет $T, вариант $V   $(hostname)   $(date '+%F %T')"
echo "=============================================="
echo "== Служба =="

# ======================================================
#  БИЛЕТ 1. DNS
# ======================================================
d() { dig @127.0.0.1 +short +time=3 +tries=1 "$@" 2>/dev/null; }
dhas() { local want="$1"; shift; d "$@" | grep -qxF -- "$want"; }

if [ "$T" = 1 ]; then
  if ! command -v dig >/dev/null; then echo "  !! не установлен dig (пакет dnsutils / bind9-dnsutils)"; fi
  if [ "$V" = 1 ]; then
    t11_4() { dhas "10 mail.exam1.local." exam1.local MX && dhas 192.168.100.20 mail.exam1.local A; }
    chk SVC "зона exam1.local загружена (SOA отвечает)" test -n "$(d exam1.local SOA)"
    chk SVC "www.exam1.local -> 192.168.100.10" dhas 192.168.100.10 www.exam1.local A
    chk SVC "ftp.exam1.local — CNAME на www.exam1.local." dhas www.exam1.local. ftp.exam1.local CNAME
    chk SVC "MX 10 mail.exam1.local. и mail -> 192.168.100.20" t11_4
    chk SVC "обратная зона: 192.168.100.10 -> www.exam1.local." dhas www.exam1.local. -x 192.168.100.10
  else
    t12_2() { dhas 10.10.10.5 srv.exam2.local A && dhas 10.10.10.6 db.exam2.local A; }
    t12_4() { dhas "20 srv.exam2.local." exam2.local MX && dhas '"exam v2"' exam2.local TXT; }
    t12_5() { dhas srv.exam2.local. -x 10.10.10.5 && dhas db.exam2.local. -x 10.10.10.6; }
    chk SVC "зона exam2.local загружена (SOA отвечает)" test -n "$(d exam2.local SOA)"
    chk SVC "srv -> 10.10.10.5 и db -> 10.10.10.6" t12_2
    chk SVC "app.exam2.local — CNAME на srv.exam2.local." dhas srv.exam2.local. app.exam2.local CNAME
    chk SVC "MX 20 srv.exam2.local. и TXT \"exam v2\"" t12_4
    chk SVC "обратная зона: .5 -> srv, .6 -> db" t12_5
  fi
fi

# ======================================================
#  БИЛЕТ 2. Веб-сервер
# ======================================================
hb() { local h="$1" p="$2"; shift 2; curl -s -m 5 -H "Host: $h" "$@" "http://127.0.0.1$p"; }
hc() { local h="$1" p="$2"; shift 2; curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Host: $h" "$@" "http://127.0.0.1$p"; }

web_up() {
  local n=0
  systemctl is-active --quiet apache2 && n=$((n + 1))
  systemctl is-active --quiet nginx && n=$((n + 1))
  [ "$n" -eq 1 ] && listen 80
}

if [ "$T" = 2 ]; then
  if [ "$V" = 1 ]; then
    w1_2() { hb exam1.local / | grep -q EXAM1-OK; }
    w1_3() { [ "$(hc admin.exam1.local /)" = 401 ]; }
    w1_4() { [ "$(hc admin.exam1.local / -u "examuser:$PW")" = 200 ]; }
    w1_5() { hb admin.exam1.local / -u "examuser:$PW" | grep -q ADMIN-OK && ! hb exam1.local / | grep -q ADMIN-OK; }
    chk SVC "запущен ровно один веб-сервер, слушает :80" web_up
    chk SVC "exam1.local отдаёт EXAM1-OK" w1_2
    chk SVC "admin.exam1.local без пароля -> 401" w1_3
    chk SVC "admin.exam1.local с examuser:Exam2024! -> 200" w1_4
    chk SVC "админ-хост отдаёт ADMIN-OK, exam1.local его не показывает" w1_5
  else
    w2_3() { hb shop.exam2.local /static/test.txt | grep -q STATIC-OK; }
    w2_4() { [ "$(hc shop.exam2.local /private/)" = 403 ]; }
    w2_5() { local c; c="$(hc shop.exam2.local /static/)"; [ "$c" = 403 ] || [ "$c" = 404 ]; }
    chk SVC "запущен ровно один веб-сервер, слушает :80" web_up
    chk SVC "shop.exam2.local отдаёт SHOP-OK" bash -c "curl -s -m 5 -H 'Host: shop.exam2.local' http://127.0.0.1/ | grep -q SHOP-OK"
    chk SVC "/static/test.txt отдаёт STATIC-OK" w2_3
    chk SVC "/private/ -> 403" w2_4
    chk SVC "листинг /static/ выключен (403 или 404)" w2_5
  fi
fi

# ======================================================
#  БИЛЕТ 3. reverse proxy
# ======================================================
seq_of() { local i out=""; for i in $(seq 1 "$2"); do out+="$(hb "$1" / | tr -d '[:space:]')|"; done; echo "$out"; }
cnt() { echo "$1" | tr '|' '\n' | grep -c -- "$2"; }
alternates() { echo "$1" | tr '|' '\n' | awk 'NF { if (NR > 1 && $0 == prev) bad = 1; prev = $0 } END { exit bad + 0 }'; }
nginx_up() { systemctl is-active --quiet nginx && listen 80; }

if [ "$T" = 3 ]; then
  if [ "$V" = 1 ]; then
    SEQ="$(seq_of proxy.exam1.local 6)"
    p1_2() { curl -s -m 5 http://127.0.0.1:8081/ | grep -q BACKEND-1 && curl -s -m 5 http://127.0.0.1:8082/ | grep -q BACKEND-2; }
    p1_3() { [ "$(cnt "$SEQ" BACKEND-1)" -ge 1 ] && [ "$(cnt "$SEQ" BACKEND-2)" -ge 1 ]; }
    p1_4() { p1_3 && alternates "$SEQ"; }
    p1_5() { nginx -t && grep -rqE '^[[:space:]]*upstream[[:space:]]' /etc/nginx/; }
    chk SVC "nginx запущен и слушает :80" nginx_up
    chk SVC "оба backend'а отвечают напрямую (8081, 8082)" p1_2
    chk SVC "через прокси приходят ответы от обоих backend'ов" p1_3
    chk SVC "ответы чередуются (Round Robin)" p1_4
    chk SVC "nginx -t проходит, в конфигурации есть upstream" p1_5
  else
    SEQ="$(seq_of proxy.exam2.local 8)"
    p2_2() { curl -s -m 5 http://127.0.0.1:8091/ | grep -q NODE-A && curl -s -m 5 http://127.0.0.1:8092/ | grep -q NODE-B; }
    p2_3() { [ "$(cnt "$SEQ" NODE-A)" -ge 1 ] && [ "$(cnt "$SEQ" NODE-B)" -ge 1 ]; }
    p2_4() { [ "$(cnt "$SEQ" NODE-A)" -ge 5 ] && [ "$(cnt "$SEQ" NODE-B)" -ge 1 ]; }
    p2_5() { curl -sI -m 5 -H 'Host: proxy.exam2.local' http://127.0.0.1/ | grep -qi '^X-Proxy: exam2'; }
    chk SVC "nginx запущен и слушает :80" nginx_up
    chk SVC "оба backend'а отвечают напрямую (8091, 8092)" p2_2
    chk SVC "через прокси приходят ответы от обоих backend'ов" p2_3
    chk SVC "из 8 запросов: A не меньше 5, B не меньше 1 (веса 3:1)" p2_4
    chk SVC "заголовок X-Proxy: exam2" p2_5
  fi
fi

# ======================================================
#  БИЛЕТ 4. Samba / NFS
# ======================================================
smbrun() { smbclient //127.0.0.1/exam -U "$1%$PW" -c "$2" 2>&1; }

if [ "$T" = 4 ]; then
  if [ "$V" = 1 ]; then
    s1_1() { systemctl is-active --quiet smbd && testparm -s 2>/dev/null | grep -q '^\[exam\]'; }
    s1_2() { smbclient -L //127.0.0.1 -U "exam1%$PW" 2>&1 | grep -qw exam; }
    s1_3() { smbrun exam1 "put $TMP/f.txt chk_exam1.txt" >/dev/null; test -f /srv/exam/samba/chk_exam1.txt; }
    s1_4() { smbrun exam2 ls | grep -qE 'NT_STATUS_(ACCESS_DENIED|LOGON_FAILURE)'; }
    s1_5() {
      [ "$(stat -c %U:%G /srv/exam/samba/chk_exam1.txt 2>/dev/null)" = "exam1:examgrp" ] &&
        [ "$(stat -c %a /srv/exam/samba 2>/dev/null)" = 2770 ]
    }
    chk SVC "smbd запущен, в testparm -s есть [exam]" s1_1
    chk SVC "smbclient -L показывает шару exam" s1_2
    chk SVC "exam1 записывает файл в шару" s1_3
    chk SVC "exam2 в шару не допускается" s1_4
    chk SVC "файл exam1:examgrp, на каталоге права 2770" s1_5
    rm -f /srv/exam/samba/chk_exam1.txt
  else
    n_1() { systemctl is-active --quiet nfs-server || systemctl is-active --quiet nfs-kernel-server; }
    n_1b() { n_1 && exportfs -v | grep -q '/srv/exam/nfs'; }
    n_2() { exportfs -v | grep -q '127.0.0.1(' && ! exportfs -v | grep -q '<world>'; }
    n_3() { [ "$(findmnt -no FSTYPE /mnt/exam-nfs 2>/dev/null)" = nfs4 ]; }
    n_4() {
      echo chk > /mnt/exam-nfs/chk_nfs.txt && [ "$(stat -c %U /srv/exam/nfs/chk_nfs.txt)" = nobody ]
    }
    n_5() {
      grep -E '^[[:space:]]*[^#].*/mnt/exam-nfs' /etc/fstab | grep -q '_netdev' &&
        grep -E '^[[:space:]]*[^#].*/mnt/exam-nfs' /etc/fstab | grep -q 'nofail'
    }
    chk SVC "NFS-сервер запущен, exportfs -v показывает /srv/exam/nfs" n_1b
    chk SVC "экспорт только для 127.0.0.1 (нет <world>)" n_2
    chk SVC "/mnt/exam-nfs смонтирован, тип nfs4" n_3
    chk SVC "файл от root на сервере принадлежит nobody (root_squash)" n_4
    chk SVC "в fstab есть запись с _netdev и nofail" n_5
    rm -f /mnt/exam-nfs/chk_nfs.txt /srv/exam/nfs/chk_nfs.txt 2>/dev/null
  fi
fi

# ======================================================
#  БИЛЕТ 5. FTP
# ======================================================
FTPC() { curl -s -m 8 "$@"; }

if [ "$T" = 5 ]; then
  ftp_up() { systemctl is-active --quiet proftpd && listen 21; }
  if [ "$V" = 1 ]; then
    A='anonymous:chk@exam.local'
    f1_2() { FTPC --user "$A" ftp://127.0.0.1/ -l >/dev/null; }
    f1_3() { FTPC --user "$A" ftp://127.0.0.1/hello.txt | grep -q FTP-PUB-OK; }
    f1_4() { f1_2 && ! FTPC --user "$A" -T "$TMP/f.txt" ftp://127.0.0.1/anon_up.txt; }
    f1_5() { f1_2 && ! FTPC --user "$A" ftp://127.0.0.1//etc/passwd | grep -q 'root:'; }
    chk SVC "proftpd запущен и слушает :21" ftp_up
    chk SVC "анонимный вход работает, список виден" f1_2
    chk SVC "hello.txt скачивается, содержимое FTP-PUB-OK" f1_3
    chk SVC "загрузка файла анонимом отклоняется" f1_4
    chk SVC "анониму не виден /etc/passwd" f1_5
    rm -f /srv/ftp/pub/anon_up.txt
  else
    U="examftp:$PW"
    f2_2() { FTPC --user "$U" ftp://127.0.0.1/ -l >/dev/null; }
    f2_3() { FTPC --user "$U" -T "$TMP/f.txt" ftp://127.0.0.1/chk_up.txt && test -f /srv/ftp/exam/chk_up.txt; }
    f2_4() { f2_2 && ! FTPC --user "$U" ftp://127.0.0.1//etc/passwd | grep -q 'root:'; }
    f2_5() { f2_2 && ! getent passwd examftp >/dev/null && ! FTPC --user "examftp:wrong-password" ftp://127.0.0.1/ -l >/dev/null; }
    chk SVC "proftpd запущен и слушает :21" ftp_up
    chk SVC "вход examftp с верным паролем успешен" f2_2
    chk SVC "загрузка работает, файл появился в /srv/ftp/exam" f2_3
    chk SVC "пользователь заперт: /etc/passwd сервера не виден" f2_4
    chk SVC "неверный пароль отклоняется, examftp нет в /etc/passwd" f2_5
    rm -f /srv/ftp/exam/chk_up.txt
  fi
fi

# ======================================================
#  БИЛЕТ 6. Почта
# ======================================================
send_mail() {
  python3 - "$1" "$2" <<'PY'
import smtplib, sys
from email.message import EmailMessage
m = EmailMessage()
m["From"] = "chk@exam.local"
m["To"] = sys.argv[1]
m["Subject"] = sys.argv[2]
m.set_content("exam check")
s = smtplib.SMTP("127.0.0.1", 25, timeout=10)
s.send_message(m)
s.quit()
PY
}
wait_mail() {
  local u="$1" m="$2" i
  for i in 1 2 3 4 5 6 7 8; do
    grep -rlq "$m" "/home/$u/Maildir/new" "/home/$u/Maildir/cur" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
mail_to() { local mark="EXAMCHK-$RANDOM$RANDOM"; send_mail "$1" "$mark" && wait_mail "$2" "$mark"; }

if [ "$T" = 6 ]; then
  pf_up() { systemctl is-active --quiet postfix && listen 25; }
  mb() { [ "$(postconf -h home_mailbox 2>/dev/null)" = "Maildir/" ]; }
  if [ "$V" = 1 ]; then
    m1_2() { postconf -h mydestination | tr ',' '\n' | tr -d '[:space:]' | grep -qxF exam1.local; }
    chk SVC "Postfix запущен и слушает :25" pf_up
    chk SVC "mydestination содержит exam1.local" m1_2
    chk SVC "home_mailbox = Maildir/" mb
    chk SVC "письмо для bob@exam1.local попало в Maildir bob" mail_to bob@exam1.local bob
    chk SVC "письмо для alice@exam1.local попало в Maildir alice" mail_to alice@exam1.local alice
  else
    m2_2() { postconf -h virtual_alias_domains | tr ',' ' ' | tr -s ' ' '\n' | grep -qxF exam2.local; }
    m2_3() { [ -n "$(postconf -h virtual_alias_maps)" ] && mb; }
    chk SVC "Postfix запущен и слушает :25" pf_up
    chk SVC "virtual_alias_domains содержит exam2.local" m2_2
    chk SVC "задан virtual_alias_maps и home_mailbox = Maildir/" m2_3
    chk SVC "info@exam2.local -> Maildir bob" mail_to info@exam2.local bob
    chk SVC "sales@exam2.local -> Maildir alice" mail_to sales@exam2.local alice
  fi
fi

# ======================================================
#  Мониторинг (Prometheus, одинаково для всех билетов)
# ======================================================
echo "== Мониторинг (Prometheus) =="

prom_val() {
  curl -s -m 5 -G 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=$1" |
    python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["data"]["result"]
    print(r[0]["value"][1] if r else "NONE")
except Exception:
    print("ERR")'
}
is_pos() { [ "$1" != NONE ] && [ "$1" != ERR ] && [ -n "$1" ] && awk -v v="$1" 'BEGIN { exit !(v > 0) }'; }

PQ="sum(node_systemd_unit_state{name=~\"$REGEX\",state=\"active\"})"
wait_state() { # wait_state pos|zero <секунд>
  local want="$1" t="$2" v i
  for ((i = 0; i < t; i += 2)); do
    v="$(prom_val "$PQ")"
    if [ "$want" = pos ] && is_pos "$v"; then return 0; fi
    if [ "$want" = zero ] && [ "$v" = 0 ]; then return 0; fi
    sleep 2
  done
  return 1
}
mon_flap() {
  local s1=0 s2=0
  systemctl stop "$CTL"
  wait_state zero 45 && s1=1
  systemctl start "$CTL"
  wait_state pos 45 && s2=1
  [ "$s1" = 1 ] && [ "$s2" = 1 ]
}
mon_up() { is_pos "$(prom_val 'max(up{instance=~".*:9100"})')"; }
mon_active() { is_pos "$(prom_val "$PQ")"; }

echo "  служба для мониторинга: $CTL"
chk MONS "Prometheus отвечает и видит node_exporter (:9100): up = 1" mon_up
chk MONS "состояние службы $CTL в метриках доступно и равно 1" mon_active

if ! mon_active >/dev/null 2>&1; then
  echo "  FAIL    0  остановка даёт 0, запуск возвращает 1 (метрика службы недоступна, службу не трогаю)"
elif [ "$FLAP" = 0 ]; then
  echo "  --      0  остановка/запуск не проверялись (--no-flap), показать преподавателю вручную"
else
  echo "  ... останавливаю $CTL и жду реакцию Prometheus (до 45 с), затем запускаю обратно"
  chk MONS "остановка даёт 0, запуск возвращает 1" mon_flap
  systemctl is-active --quiet "$CTL" || systemctl start "$CTL"
fi

echo "=============================================="
echo " Служба: $SVC / 50    Мониторинг: $MONS / 30    Практика: $((SVC + MONS)) / 80"
echo " (к этому добавляются 20 баллов за тест)"
echo "=============================================="
