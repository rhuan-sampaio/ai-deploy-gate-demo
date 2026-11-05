# Funções comuns dos scripts do pipeline (carregado com "source").
# Variáveis: SN_INSTANCE (ex.: minhainstancia.service-now.com), SN_USER, SN_PASS
#            OUT_DIR (padrão: out)  |  SN_BASE_URL sobrescreve a URL (usado nos testes locais)

OUT=${OUT_DIR:-out}
mkdir -p "$OUT"

SN_INSTANCE=${SN_INSTANCE:-}
SN_INSTANCE=${SN_INSTANCE#https://}
SN_INSTANCE=${SN_INSTANCE%/}
SN_BASE_URL=${SN_BASE_URL:-https://$SN_INSTANCE}
SN_BASE_URL=${SN_BASE_URL%/}

# Chamada REST ao ServiceNow. Uso: sn METODO /caminho [json]
sn() {
  : "${SN_INSTANCE:?defina SN_INSTANCE}" "${SN_USER:?defina SN_USER}" "${SN_PASS:?defina SN_PASS}"
  local method=$1 path=$2 data=${3:-} resp code
  local args=(-sS -u "$SN_USER:$SN_PASS" -H "Accept: application/json" -X "$method" -w $'\n%{http_code}')
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" --data "$data")
  resp=$(curl "${args[@]}" "$SN_BASE_URL$path") || { echo "::error::Sem conexão com o ServiceNow ($SN_BASE_URL)" >&2; return 1; }
  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}
  if [ "$code" -ge 400 ]; then
    echo "::error::ServiceNow respondeu HTTP $code em $method ${path%%\?*}: $(echo "$resp" | jq -r '.error.message // .error.detail // .' 2>/dev/null | head -c 400)" >&2
    return 1
  fi
  printf '%s' "$resp"
}

# Anexa um arquivo a um registro. Uso: sn_attach tabela sys_id arquivo nome
sn_attach() {
  curl -sS -f -o /dev/null -u "$SN_USER:$SN_PASS" -H "Accept: application/json" -H "Content-Type: application/json" \
    --data-binary @"$3" "$SN_BASE_URL/api/now/attachment/file?table_name=$1&table_sys_id=$2&file_name=$(urlenc "$4")"
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# Resumo visual do job (aba Summary do GitHub Actions); fora do Actions, imprime no terminal
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then tee -a "$GITHUB_STEP_SUMMARY"; else cat; fi; }

# Saída do step (lida pelos jobs seguintes)
output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; else echo "  [output] $1=$2"; fi; }

ESTADOS_CHG='{"-5":"New","-4":"Assess","-3":"Authorize","-2":"Scheduled","-1":"Implement","0":"Review","3":"Closed","4":"Canceled"}'
estado() { jq -rn --argjson e "$ESTADOS_CHG" --arg s "$1" '$e[$s] // $s'; }
