#!/bin/bash
# fake_docker_login.sh -- simule « docker login -u USER --password-stdin REGISTRY » (Mission 2)
#
# Le conteneur CI n'a pas de démon Docker : ce script reproduit le contrat de
# --password-stdin (secret lu sur l'entrée standard, jamais en argument) sans
# contacter de registre. Il n'affiche jamais le secret, seulement sa longueur.
set -euo pipefail

user=""; from_stdin=0; registry="docker.io"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--username)    user="$2"; shift 2 ;;
        --password-stdin) from_stdin=1; shift ;;
        -p|--password)
            echo "Refusé : -p expose le secret dans la ligne de commande (ps, /proc, historique)." >&2
            exit 2 ;;
        *) registry="$1"; shift ;;
    esac
done

[[ ${from_stdin} -eq 1 ]] || { echo "usage : echo \"\$TOKEN\" | $0 -u USER --password-stdin [REGISTRY]" >&2; exit 2; }
IFS= read -r secret || true
[[ -n "${secret}" ]] || { echo "Erreur : aucun secret reçu sur stdin (variable vide ?)" >&2; exit 1; }

echo "Login Succeeded (simulation) : ${user:-?}@${registry}, secret de ${#secret} caractères reçu via stdin"
