#!/usr/bin/env bash
# Avaliação do modelo antes do deploy (simulada): compara model/eval-results.json com model/thresholds.json.
# Falha o pipeline se alguma métrica estourar o limite. SIMULAR_FALHA=true degrada as métricas para a demo.
# Gera $OUT_DIR/eval-report.json (vai como evidência para o Change Request).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

# Métricas da avaliação de cada AI System: model/<asset tag>.json
RES=model/${AI_ASSET_TAG:-sem-asset-tag}.json
if [ ! -f "$RES" ]; then
  echo "::error::Sem resultado de avaliação para o AI System ${AI_ASSET_TAG:-?} (esperado: $RES)"
  printf '### ⛔ Avaliação do modelo\n\nNão há resultado de avaliação para o asset tag `%s` (arquivo `%s`). Nenhum deploy sem avaliação.\n' "${AI_ASSET_TAG:-?}" "$RES" | summary
  exit 1
fi
metricas=$(jq '.metricas' "$RES")
if [ "${SIMULAR_FALHA:-false}" = "true" ]; then
  echo "::warning::Simulando avaliação reprovada (acurácia e alucinação degradadas)"
  metricas=$(echo "$metricas" | jq '.acuracia = 0.821 | .taxa_alucinacao = 0.114')
fi

jq -n --argjson m "$metricas" --slurpfile lim model/thresholds.json --slurpfile res "$RES" '
  {modelo: $res[0].modelo, versao: (env.VERSAO // $res[0].versao), conjunto: $res[0].conjunto,
   avaliado_em: (now | todate),
   metricas: [ $lim[0] | to_entries[] | .key as $k | .value as $v | $m[$k] as $x |
     { metrica: $k, rotulo: $v.rotulo, valor: $x,
       limite: (if $v.min != null then "≥ \($v.min)" else "≤ \($v.max)" end),
       ok: (if $x == null then false elif $v.min != null then $x >= $v.min else $x <= $v.max end) } ] }
  | .aprovado = all(.metricas[]; .ok)' > "$OUT/eval-report.json"

jq -r '
  "### 🧪 Avaliação do modelo — \(.modelo) v\(.versao)", "",
  "Conjunto: \(.conjunto)", "",
  "| Métrica | Valor | Limite | |", "|---|---:|---:|:-:|",
  (.metricas[] | "| \(.rotulo) | \(.valor // "—") | \(.limite) | \(if .ok then "✅" else "⛔" end) |"), "",
  "**Resultado:** \(if .aprovado then "✅ aprovado para seguir ao gate de governança" else "⛔ reprovado — o pipeline para aqui, nenhum Change é aberto" end)", ""
' "$OUT/eval-report.json" | summary

[ "$(jq -r '.aprovado' "$OUT/eval-report.json")" = "true" ] || { echo "::error::Avaliação do modelo reprovada"; exit 1; }
