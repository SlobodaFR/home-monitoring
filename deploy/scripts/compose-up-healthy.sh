#!/bin/sh
# compose-up-healthy.sh : `docker compose up -d` qui n'est vert que si les conteneurs deviennent sains.
# Convention du harnais `deploy-wait-healthy` (home-harness, CONVENTIONS.md v1.4).
# COPIE VERBATIM depuis home-harness/scripts/compose-up-healthy.sh : ne jamais modifier la copie d'un repo
# (l'audit compare les deux fichiers). Un changement se fait dans le harnais.
#
# Usage (depuis le dossier du docker-compose.yml, sous le verrou d'hôte, APRÈS pre-deploy-backup) :
#   sh compose-up-healthy.sh [--service <svc>] [--restore-args '<args de restore-sqlite-backup.sh>'] \
#        [--timeout 180] [--log-lines 100] [-- <options supplémentaires de `docker compose up`>]
#
# Principe :
#   1. `docker compose up -d --wait --wait-timeout <timeout>` si Compose le connaît (détection dans l'aide de
#      `docker compose up`) ; sinon `up -d` puis une boucle qui interroge `docker inspect` (état + santé de chaque
#      conteneur du projet) jusqu'au délai. Même verdict dans les deux modes ;
#   2. sain = `running` et (`healthy` ou aucun HEALTHCHECK) ; un conteneur terminé avec le code 0 est accepté
#      (tâche ponctuelle) ; `unhealthy`, terminé en erreur, en boucle de redémarrage, ou encore en démarrage à
#      l'échéance = échec ;
#   3. en cas d'échec : les $LOG_LINES (100) dernières lignes de chaque conteneur fautif (les logs sont sans donnée
#      personnelle par convention), le chemin de la sauvegarde d'avant-déploiement la plus récente du service
#      (--service) et la commande de restauration, puis sortie 1 : le job est rouge.
#      AUCUN retour arrière automatique : redéployer le tag d'image précédent à la main et, si une migration a
#      tourné, restaurer la sauvegarde (`--no-start` d'abord, voir CONVENTIONS.md).
#
# Options : --service <svc> (sauvegarde cherchée dans $BACKUP_ROOT/<svc>/<svc>-*.sqlite ; omis = aucun SQLite),
# --restore-args (paramètres de restore-sqlite-backup.sh : --project --volume --mount --db-path), --timeout (180 s,
# aussi HEALTHY_TIMEOUT), --log-lines (100). Autres variables : BACKUP_ROOT ($HOME/backups),
# HEALTHY_POLL_INTERVAL (2 s, mode de repli).
#
# Sortie (jeton stable à chercher dans le journal) : `[deploy-wait-healthy] <svc>: status=OK mode=wait|poll …`
# ou `… status=FAIL …`. POSIX sh (dash, busybox, bash).
set -eu

PREFIX='[deploy-wait-healthy]'
SERVICE=''
RESTORE_ARGS=''
TIMEOUT="${HEALTHY_TIMEOUT:-180}"
LOG_LINES=100
INTERVAL="${HEALTHY_POLL_INTERVAL:-2}"
BACKUP_ROOT="${BACKUP_ROOT:-${HOME:-}/backups}"
SELF_DIR=$(cd "$(dirname "$0")" && pwd)

log() { printf '%s %s: %s\n' "$PREFIX" "${SERVICE:-compose}" "$*"; }
usage() {
  printf 'Usage : sh compose-up-healthy.sh [--service <svc>] [--restore-args <args>] [--timeout <s>] [--log-lines <n>] [-- <options de docker compose up>]\n' >&2
  exit 2
}
is_number() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --service) [ $# -ge 2 ] || usage; SERVICE="$2"; shift 2 ;;
    --restore-args) [ $# -ge 2 ] || usage; RESTORE_ARGS="$2"; shift 2 ;;
    --timeout) [ $# -ge 2 ] || usage; TIMEOUT="$2"; shift 2 ;;
    --log-lines) [ $# -ge 2 ] || usage; LOG_LINES="$2"; shift 2 ;;
    --) shift; break ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done
is_number "$TIMEOUT" || usage
is_number "$LOG_LINES" || usage
is_number "$INTERVAL" || usage

# "<nom>|<état>|<santé>|<code de sortie>" d'un conteneur ; santé = none sans HEALTHCHECK.
describe() {
  docker inspect -f '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.ExitCode}}' "$1" | sed 's#^/##'
}

# verdict "<état>|<santé>|<code>" : ok | pending | bad
verdict() {
  case "$1" in
    running\|healthy\|* | running\|none\|*) echo ok ;;
    running\|starting\|* | created\|* | paused\|* | removing\|*) echo pending ;;
    exited\|*\|0) echo ok ;;
    *) echo bad ;;
  esac
}

project_containers() { docker compose ps -a -q; }

summary() {
  for id in $(project_containers); do
    line=$(describe "$id")
    name=${line%%|*}
    rest=${line#*|}
    printf '  %s : %s\n' "$name" "$(printf '%s' "$rest" | awk -F'|' '{ printf "état=%s santé=%s code=%s", $1, $2, $3 }')"
  done
}

report_failure() {
  reason="$1"
  log "status=FAIL $reason"
  summary
  shown=0
  for id in $(project_containers); do
    line=$(describe "$id")
    [ "$(verdict "${line#*|}")" = ok ] && continue
    shown=1
    printf '%s %s dernières %s lignes de %s :\n' "$PREFIX" "${SERVICE:-compose}" "$LOG_LINES" "${line%%|*}"
    docker logs --tail "$LOG_LINES" "$id" 2>&1 || true
    printf '%s fin des logs de %s\n' "$PREFIX" "${line%%|*}"
  done
  [ "$shown" = 1 ] || log "aucun conteneur fautif identifié (voir la sortie de docker compose ci-dessus)"
  backup=''
  if [ -n "$SERVICE" ] && [ -d "$BACKUP_ROOT/$SERVICE" ]; then
    # Le nom contient l'horodatage UTC : le tri lexicographique donne la plus récente, celle prise avant CE déploiement.
    backup=$(ls -1 "$BACKUP_ROOT/$SERVICE" 2>/dev/null | grep "^$SERVICE-.*\.sqlite$" | sort | tail -n 1 || true)
  fi
  if [ -n "$backup" ]; then
    log "sauvegarde d'avant-déploiement : $BACKUP_ROOT/$SERVICE/$backup"
    log "restauration (après avoir redéployé le tag d'image précédent ; --no-start laisse les conteneurs arrêtés) : bash $SELF_DIR/restore-sqlite-backup.sh --service $SERVICE $RESTORE_ARGS --backup $BACKUP_ROOT/$SERVICE/$backup --no-start"
  elif [ -n "$SERVICE" ]; then
    log "aucune sauvegarde trouvée dans $BACKUP_ROOT/$SERVICE (premier déploiement ?) : rien à restaurer"
  fi
  log "aucun retour arrière automatique : redéployer le tag d'image précédent à la main (IMAGE_TAG=<ancien tag> docker compose up -d --wait) ; si une migration de base a tourné, restaurer d'abord la sauvegarde ci-dessus."
  exit 1
}

started=$(date +%s)
elapsed() { echo $(($(date +%s) - started)); }

# `--wait-timeout` (Compose >= 2.17) : sans lui, `--wait` n'aurait pas de délai.
if docker compose up --help 2>&1 | grep -q -- --wait-timeout; then
  MODE=wait
  if ! docker compose up -d --wait --wait-timeout "$TIMEOUT" "$@"; then
    report_failure "docker compose up --wait en échec ou délai de ${TIMEOUT} s dépassé"
  fi
else
  MODE=poll
  if ! docker compose up -d "$@"; then
    report_failure "docker compose up -d en échec"
  fi
  deadline=$((started + TIMEOUT))
  while :; do
    ids=$(project_containers)
    [ -n "$ids" ] || report_failure "aucun conteneur dans le projet après up"
    pending=0
    bad=0
    for id in $ids; do
      case "$(verdict "$(describe "$id" | cut -d'|' -f2-)")" in
        ok) ;;
        pending) pending=1 ;;
        *) bad=1 ;;
      esac
    done
    [ "$bad" = 1 ] && report_failure "conteneur en échec (unhealthy ou terminé en erreur)"
    [ "$pending" = 0 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && report_failure "délai de ${TIMEOUT} s dépassé avant que tous les conteneurs soient sains"
    sleep "$INTERVAL"
  done
fi

# Dernier regard : `--wait` accepte aussi un conteneur sans HEALTHCHECK déjà tombé ; le verdict commun tranche.
[ -n "$(project_containers)" ] || report_failure "aucun conteneur dans le projet après up"
for id in $(project_containers); do
  [ "$(verdict "$(describe "$id" | cut -d'|' -f2-)")" = ok ] || report_failure "conteneur non sain après up"
done
log "status=OK mode=$MODE elapsed=$(elapsed)s timeout=${TIMEOUT}s"
summary
