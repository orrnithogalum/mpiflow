#!/bin/bash
# submit_and_poll.sh -- soumet un job Slurm et suit son état jusqu'au bout (Mission 3)
#
# usage : slurm/submit_and_poll.sh <script.sh> [options sbatch...]
# env   : POLL_INTERVAL (s, défaut 30)
#
# Codes retour (lus par le job CI, GitHub ou GitLab) :
#   0  job COMPLETED avec ExitCode 0
#   1  échec de code (FAILED, TIMEOUT Slurm, OUT_OF_MEMORY, CANCELLED...)
#   75 échec d'infrastructure (NODE_FAIL, BOOT_FAIL, PREEMPTED, job remis en file,
#      état introuvable)
#      -> relançable
set -uo pipefail

script="$1"; shift
interval="${POLL_INTERVAL:-30}"

# --parsable : sortie « jobid » ou « jobid;cluster », sans phrase à analyser
jobid="$(sbatch --parsable "$@" "${script}")" || { echo "sbatch a échoué" >&2; exit 1; }
jobid="${jobid%%;*}"
echo "${jobid}" > .slurm_jobid          # relu par l'étape de nettoyage pour annuler le job
echo "Job Slurm ${jobid} soumis ($(date -Is))"

# état d'un champ du job sans passer par la base : scontrol garde les jobs terminés
# MinJobAge secondes (300 par défaut)
scontrol_field() { scontrol show job -o "${jobid}" 2>/dev/null | grep -o "$1=[^ ]*" | cut -d= -f2; }

start=$(date +%s)
state=""
shown_start=""
unknown=0
max_unknown="${MAX_UNKNOWN:-6}"
while true; do
    # -X : ligne de l'allocation seulement (pas les steps) ; -P : sortie séparée par « | »
    state="$(sacct -X -n -P -j "${jobid}" -o State 2>/dev/null | head -1)"
    state="${state%% *}"                 # « CANCELLED by 1000 » -> « CANCELLED »
    # sacct peut être vide juste après la soumission (slurmdbd pas encore à jour)
    [[ -z "${state}" ]] && state="$(squeue -h -j "${jobid}" -o %T 2>/dev/null)"
    # base de comptabilité indisponible et job sorti de la file : on interroge le contrôleur
    [[ -z "${state}" ]] && state="$(scontrol_field JobState)"
    reason="$(squeue -h -j "${jobid}" -o %r 2>/dev/null)"
    printf '[%s] +%5ss  job %s  %-10s %s\n' "$(date +%T)" "$(( $(date +%s) - start ))" \
           "${jobid}" "${state:-INCONNU}" "${reason:+raison=${reason}}"

    # job déjà démarré puis remis en file par Slurm (NODE_FAIL et requeue automatique)
    if [[ "${state}" == PENDING && "$(scontrol_field Restarts)" -gt 0 ]] 2>/dev/null; then
        echo "job remis en file par Slurm après une panne (Restarts=$(scontrol_field Restarts))"
        state=REQUEUED
        break
    fi
    case "${state}" in
        PENDING)
            # la raison vaut « None » tant que l'ordonnanceur n'a pas évalué le job
            if [[ -z "${shown_start}" && "${reason}" != "None" ]]; then
                squeue -h --start -j "${jobid}" -o '   début estimé par Slurm : %S'
                shown_start=1
            fi ;;
        COMPLETED|FAILED|TIMEOUT|CANCELLED|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|PREEMPTED|DEADLINE)
            break ;;
        "")
            # ni sacct, ni squeue, ni scontrol : inutile d'attendre le timeout du CI
            unknown=$((unknown + 1))
            if (( unknown >= max_unknown )); then
                echo "Verdict : état du job introuvable après ${unknown} tentatives (comptabilité indisponible ?)" >&2
                exit 75
            fi ;;
        *) unknown=0 ;;
    esac
    sleep "${interval}"
done

# la comptabilité (slurmdbd) est asynchrone : juste après la fin du job, sacct peut
# encore afficher JobName=allocation et une liste de nœuds incomplète
sleep "${SACCT_SETTLE:-5}"
echo "---- sacct ----"
sacct -D -j "${jobid}" -o JobID,JobName%14,State,ExitCode,Elapsed,NNodes,NodeList%16 2>&1 | tee "sacct-${jobid}.txt"
echo "---- sortie du job ----"
cat "ci-${jobid}.out" 2>/dev/null || echo "(pas de fichier ci-${jobid}.out)"

exitcode="$(sacct -X -n -P -j "${jobid}" -o ExitCode 2>/dev/null | head -1)"   # « code:signal »
[[ -z "${exitcode}" ]] && exitcode="$(scontrol_field ExitCode)"                 # repli sans base
case "${state}" in
    COMPLETED)
        if [[ "${exitcode%%:*}" == 0 ]] && grep -q '^SUCCESS' "ci-${jobid}.out"; then
            echo "Verdict : succès"; exit 0
        fi
        echo "Verdict : COMPLETED mais ExitCode=${exitcode} ou SUCCESS absent"; exit 1 ;;
    NODE_FAIL|BOOT_FAIL|PREEMPTED|REQUEUED)
        echo "Verdict : échec d'INFRASTRUCTURE (${state}) -> relance possible" >&2; exit 75 ;;
    *)
        echo "Verdict : échec du JOB (${state}, ExitCode=${exitcode})" >&2; exit 1 ;;
esac
