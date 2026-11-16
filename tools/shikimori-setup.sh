#!/bin/sh
# Сохраняет ключи приложения Шикимори (https://shikimori.io/oauth/applications) в shikimori.local.json
# в корне репозитория. Файл в .gitignore; ввод скрыт и нигде не печатается.
set -e
cd "$(dirname "$0")/.."
printf 'Client ID: '; stty -echo; read -r id; stty echo; echo
printf 'Client Secret: '; stty -echo; read -r secret; stty echo; echo
case "$id$secret" in *[!A-Za-z0-9_-]*|'') echo 'Ключи должны состоять из латиницы, цифр, - и _'; exit 1;; esac
umask 077
printf '{"client_id":"%s","client_secret":"%s"}\n' "$id" "$secret" > shikimori.local.json
echo "Сохранено в $(pwd)/shikimori.local.json"
