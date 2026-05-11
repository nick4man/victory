#!/usr/bin/env bash
# E5 — Скан секретов в git-истории/diff-е audit-engine-v2.
#
# Что делает:
#   - проверяет staged-файлы (если --staged) или PR-diff (если CI_PR_BASE задан),
#   - ищет паттерны: TG-токены, Gemini-ключи, AWS-ключи, generic API-keys, JWT,
#   - возвращает exit-code 1 при найденном секрете → CI валится.
#
# Альтернатива: trufflehog/gitleaks. Здесь — лёгкая bash-обёртка без зависимостей.
# Полную проверку поверх всей git-истории делает gitleaks (если установлен).
#
# Использование:
#   ./scripts/check_secrets_in_git.sh                       # дифф против origin/master
#   ./scripts/check_secrets_in_git.sh --staged              # только staged
#   ./scripts/check_secrets_in_git.sh --base origin/main    # дифф против указанной ветки
#   ./scripts/check_secrets_in_git.sh --files file1.py f2.py  # конкретные файлы

set -uo pipefail

MODE="diff"
BASE_REF="${CI_PR_BASE:-origin/master}"
EXPLICIT_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged) MODE="staged"; shift ;;
        --base) BASE_REF="$2"; shift 2 ;;
        --files) shift; while [[ $# -gt 0 && "$1" != --* ]]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        --help|-h) head -25 "$0"; exit 0 ;;
        *) echo "unknown: $1"; exit 2 ;;
    esac
done

# -----------------------------------------------------------------------
# Что сканируем
# -----------------------------------------------------------------------

if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    FILES=("${EXPLICIT_FILES[@]}")
elif [[ "$MODE" == "staged" ]]; then
    mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACM)
else
    if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
        echo "⚠️  base ref $BASE_REF недоступен; скан текущего рабочего диффа"
        mapfile -t FILES < <(git diff --name-only --diff-filter=ACM HEAD)
    else
        mapfile -t FILES < <(git diff --name-only --diff-filter=ACM "$BASE_REF"...HEAD)
    fi
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "✅ Нет файлов для сканирования"
    exit 0
fi

# Фильтруем — игнорируем data-фикстуры, README, и явные whitelist
TARGETS=()
for f in "${FILES[@]}"; do
    case "$f" in
        */.env.example|*/test_*|tests/fixtures/*|*.md|*.html|*.lock) continue ;;
        *) [[ -f "$f" ]] && TARGETS+=("$f") ;;
    esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "✅ После фильтров — нечего сканировать"
    exit 0
fi

# -----------------------------------------------------------------------
# Паттерны секретов
# -----------------------------------------------------------------------
# perl -nE для multiline-PCRE-ext, печатает имя файла:строка:совпадение
PATTERNS=(
    # Telegram Bot Token: <numbers>:<35chars>
    '\b\d{8,11}:[A-Za-z0-9_-]{35}\b'
    # Gemini API key: AIzaSy + 33 chars
    '\bAIzaSy[A-Za-z0-9_-]{33}\b'
    # OpenAI sk- / Anthropic sk-ant-
    '\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}\b'
    # AWS Access Key Id
    '\bAKIA[0-9A-Z]{16}\b'
    # JWT (header.payload.signature, base64url)
    '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b'
    # Generic password literals
    'password\s*[:=]\s*["\047][A-Za-z0-9_!@#$%^&*-]{8,}["\047]'
    # Database URL с паролем inline
    'postgres(?:ql)?://[^:\s]+:[^@\s]+@[^/\s]+'
)

# Whitelist «известно безопасных» подстрок — fixtures с тестовыми токенами и
# плейсхолдеры из .env.example.
SAFE_REGEX='YOUR_TOKEN_HERE|REPLACE_ME|placeholder|change_me|ci_test_pwd|EXAMPLE|<token>|<password>'

FOUND=0
for file in "${TARGETS[@]}"; do
    for pat in "${PATTERNS[@]}"; do
        # `grep -nP` с фолбэком на perl
        if matches=$(perl -ne 'print "$ARGV:$.: $1\n" if /('"$pat"')/' "$file" 2>/dev/null); then
            if [[ -n "$matches" ]]; then
                # Применяем safelist
                filtered=$(echo "$matches" | grep -Ev "$SAFE_REGEX" || true)
                if [[ -n "$filtered" ]]; then
                    echo "❌ secret leak suspected in $file:"
                    echo "$filtered"
                    FOUND=$((FOUND + 1))
                fi
            fi
        fi
    done
done

if [[ $FOUND -gt 0 ]]; then
    echo ""
    echo "❌ Найдено $FOUND потенциальных секретов. См. RUNBOOK_SECRETS.md."
    echo "   Если это false-positive — добавьте паттерн в SAFE_REGEX этого скрипта"
    echo "   или вынесите значение в .env.example с плейсхолдером."
    exit 1
fi

echo "✅ Секретов не обнаружено в ${#TARGETS[@]} файлах"
exit 0
